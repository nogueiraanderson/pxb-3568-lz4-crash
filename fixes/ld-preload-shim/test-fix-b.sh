#!/usr/bin/env bash
# PXB-3568 Fix B: Test with LD_PRELOAD buffer size workaround
#
# Uses an LD_PRELOAD shim that wraps LZ4_compress_default to handle
# the undersized output buffer from the comp_buf_size bug.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
REPRODUCE_DIR="$PROJECT_DIR/reproduce"

COMPOSE="docker compose -f $REPRODUCE_DIR/docker-compose.yml -f $SCRIPT_DIR/docker-compose.override.yml"
MYSQL_CMD="mysql -uroot -proot -N"
CONTAINERS=("lz4-pxc-node1" "lz4-pxc-node2" "lz4-pxc-node3")
SST_ATTEMPTS=${SST_ATTEMPTS:-3}

log() { echo "[$(date '+%H:%M:%S')] $*"; }
err() { echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2; }

cleanup() {
    log "Cleaning up..."
    $COMPOSE down -v --remove-orphans 2>/dev/null || true
}

wait_for_cluster() {
    local expected_size="${1:-3}"
    local max_wait="${2:-300}"
    local elapsed=0
    while [ $elapsed -lt "$max_wait" ]; do
        for container in "${CONTAINERS[@]}"; do
            local size
            size=$(docker exec "$container" $MYSQL_CMD -e \
                "SHOW STATUS LIKE 'wsrep_cluster_size'" 2>/dev/null | awk '{print $2}') || continue
            if [ "$size" = "$expected_size" ]; then
                log "Cluster ready: size=$size (${elapsed}s)"
                return 0
            fi
        done
        sleep 5
        elapsed=$((elapsed + 5))
    done
    err "Timeout"
    return 1
}

wait_for_node_synced() {
    local container="$1"
    local max_wait="${2:-300}"
    local elapsed=0
    while [ $elapsed -lt "$max_wait" ]; do
        local state
        state=$(docker exec "$container" $MYSQL_CMD -e \
            "SHOW STATUS LIKE 'wsrep_local_state_comment'" 2>/dev/null | awk '{print $2}') || true
        if [ "$state" = "Synced" ]; then
            log "$container synced after ${elapsed}s"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    err "Timeout: $container did not sync"
    return 1
}

create_test_data() {
    docker exec lz4-pxc-node1 $MYSQL_CMD -e "
        CREATE DATABASE IF NOT EXISTS pxb3568;
        USE pxb3568;
        CREATE TABLE IF NOT EXISTS testdata (
            id BIGINT AUTO_INCREMENT PRIMARY KEY,
            data VARCHAR(4000),
            padding BLOB,
            ts TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        ) ENGINE=InnoDB;
    " 2>/dev/null
}

start_insert_load() {
    log "Starting continuous insert load..."
    docker exec -d lz4-pxc-node1 bash -c '
        while true; do
            mysql -uroot -proot pxb3568 -e "
                INSERT INTO testdata (data, padding)
                SELECT
                    REPEAT(CHAR(FLOOR(65 + RAND()*26)), FLOOR(100 + RAND()*3900)),
                    RANDOM_BYTES(FLOOR(1000 + RAND()*8000))
                FROM (SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5
                      UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9 UNION SELECT 10) t;
            " 2>/dev/null
            sleep 0.1
        done
    '
    log "Inserting data for 30s..."
    sleep 30
}

get_volume_name() {
    echo "reproduce_node3-data"
}

force_sst_on_node3() {
    local attempt="$1"
    log "=== Fix B: SST attempt $attempt/$SST_ATTEMPTS ==="

    docker stop lz4-pxc-node3 2>/dev/null || true
    sleep 5

    local vol
    vol=$(get_volume_name)
    docker run --rm -v "$vol:/data" alpine \
        sh -c "rm -f /data/galera.cache /data/grastate.dat /data/gvwstate.dat" 2>/dev/null || true

    sleep 10
    docker start lz4-pxc-node3

    local elapsed=0
    while [ $elapsed -lt 120 ]; do
        local status
        status=$(docker inspect -f '{{.State.Status}}' lz4-pxc-node3 2>/dev/null) || status="unknown"
        if [ "$status" = "exited" ] || [ "$status" = "dead" ]; then
            err "Node3 container died! Status: $status"
            docker logs --tail 50 lz4-pxc-node3 2>&1 || true
            return 1
        fi

        local state
        state=$(docker exec lz4-pxc-node3 $MYSQL_CMD -e \
            "SHOW STATUS LIKE 'wsrep_local_state_comment'" 2>/dev/null | awk '{print $2}') || state=""
        if [ "$state" = "Synced" ]; then
            log "Node3 synced successfully via SST with LD_PRELOAD fix"
            return 0
        fi

        sleep 5
        elapsed=$((elapsed + 5))
    done

    err "Timeout waiting for SST"
    return 1
}

main() {
    log "=== PXB-3568 Fix B: LD_PRELOAD Buffer Size Workaround ==="

    cleanup

    log "Building PXC image with LD_PRELOAD fix..."
    $COMPOSE build --no-cache 2>&1 | tail -5

    log "Starting 3-node cluster..."
    $COMPOSE up -d

    if ! wait_for_cluster 3 300; then
        err "Cluster failed to form"
        cleanup
        exit 1
    fi

    log "Verifying LD_PRELOAD shim:"
    docker exec lz4-pxc-node1 bash -c \
        "cat /etc/ld.so.preload; ls -la /usr/lib64/lz4_fix.so" 2>&1 || true

    create_test_data
    start_insert_load

    all_passed=true
    for attempt in $(seq 1 $SST_ATTEMPTS); do
        if ! force_sst_on_node3 "$attempt"; then
            all_passed=false
            break
        fi
        if [ "$attempt" -lt "$SST_ATTEMPTS" ]; then
            wait_for_node_synced lz4-pxc-node3 120 || true
            sleep 10
        fi
    done

    mkdir -p "$PROJECT_DIR/evidence"
    docker logs lz4-pxc-node1 > "$PROJECT_DIR/evidence/node1-fix-b.log" 2>&1 || true
    docker logs lz4-pxc-node3 > "$PROJECT_DIR/evidence/node3-fix-b.log" 2>&1 || true

    if [ "$all_passed" = true ]; then
        log ""
        log "=========================================="
        log "  FIX B PASSED: $SST_ATTEMPTS SST cycles with LD_PRELOAD fix"
        log "=========================================="
    else
        log ""
        log "=========================================="
        log "  FIX B FAILED: Crash still occurs with LD_PRELOAD fix"
        log "=========================================="
    fi

    cleanup
}

main "$@"
