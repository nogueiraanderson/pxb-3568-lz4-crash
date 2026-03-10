#!/usr/bin/env bash
# PXB-3568 Crash Reproduction
#
# Reproduces the LZ4 Signal 6 crash during SST on PXC 8.0.45 (EL9).
# Starts a 3-node PXC cluster, inserts data, then forces SST with
# LZ4 compression to trigger the LTO assertion bug.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$SCRIPT_DIR"

COMPOSE="docker compose"
MYSQL_CMD="mysql -uroot -proot -N"
CONTAINERS=("lz4-pxc-node1" "lz4-pxc-node2" "lz4-pxc-node3")
MAX_SST_ATTEMPTS=${MAX_SST_ATTEMPTS:-3}

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

    log "Waiting for cluster size=$expected_size (max ${max_wait}s)..."
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
    err "Timeout: cluster did not reach size=$expected_size"
    return 1
}

wait_for_node_synced() {
    local container="$1"
    local max_wait="${2:-300}"
    local elapsed=0

    log "Waiting for $container to sync (max ${max_wait}s)..."
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

check_for_crash() {
    local container="$1"
    log "Checking for Signal 6 / crash indicators on $container..."

    local logs
    logs=$(docker logs "$container" 2>&1 | tail -200)

    if echo "$logs" | grep -qiE "signal 6|sigabrt|abort|assertion.*fail|lz4.*compress"; then
        log "=== CRASH DETECTED on $container ==="
        echo "$logs" | grep -iE "signal|abort|assert|lz4|compress|backtrace|fatal" || true
        return 0
    fi
    return 1
}

create_test_data() {
    log "Creating test database and table..."
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
    log "Test table created"
}

start_insert_load() {
    log "Starting continuous insert load..."
    # Generate varied-size rows to maximize hitting the LZ4 boundary
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
    log "Inserting data for 30s to build up redo logs..."
    sleep 30

    local count
    count=$(docker exec lz4-pxc-node1 $MYSQL_CMD -e \
        "SELECT COUNT(*) FROM pxb3568.testdata" 2>/dev/null) || count="?"
    log "Rows inserted so far: $count"
}

get_volume_name() {
    # Docker Compose v2 uses directory name as project
    local project_name
    project_name=$(basename "$SCRIPT_DIR")
    echo "${project_name}_node3-data"
}

force_sst_on_node3() {
    log "=== Forcing SST on node3 (attempt $1/$MAX_SST_ATTEMPTS) ==="

    docker stop lz4-pxc-node3 2>/dev/null || true
    sleep 5

    # Delete galera state to force full SST
    local vol
    vol=$(get_volume_name)
    log "Deleting galera state (volume: $vol)..."
    docker run --rm -v "$vol:/data" alpine \
        sh -c "rm -f /data/galera.cache /data/grastate.dat /data/gvwstate.dat" 2>/dev/null || true

    log "Inserting more data while node3 is down..."
    sleep 15

    log "Starting lz4-pxc-node3 (triggers SST with LZ4 compression)..."
    docker start lz4-pxc-node3

    log "Monitoring for crash (up to 120s)..."
    local elapsed=0
    while [ $elapsed -lt 120 ]; do
        local status
        status=$(docker inspect -f '{{.State.Status}}' lz4-pxc-node3 2>/dev/null) || status="unknown"
        if [ "$status" = "exited" ] || [ "$status" = "dead" ]; then
            log "Node3 container status: $status"
            if check_for_crash lz4-pxc-node3; then
                return 0
            fi
            # Also check donor
            if check_for_crash lz4-pxc-node1; then
                return 0
            fi
        fi

        local state
        state=$(docker exec lz4-pxc-node3 $MYSQL_CMD -e \
            "SHOW STATUS LIKE 'wsrep_local_state_comment'" 2>/dev/null | awk '{print $2}') || state=""
        if [ "$state" = "Synced" ]; then
            log "Node3 synced successfully (no crash this attempt)"
            return 1
        fi

        # Check donor logs
        if check_for_crash lz4-pxc-node1; then
            return 0
        fi

        sleep 5
        elapsed=$((elapsed + 5))
    done

    log "SST attempt timed out without crash or sync"
    return 1
}

main() {
    log "=== PXB-3568 LZ4 Crash Reproduction ==="
    log "Image: ${PXC_IMAGE:-percona/percona-xtradb-cluster:8.0.45}"
    log ""

    log "Checking system LZ4 version..."
    docker run --rm "${PXC_IMAGE:-percona/percona-xtradb-cluster:8.0.45}" \
        bash -c "rpm -q lz4-libs 2>/dev/null || echo 'unknown'" 2>/dev/null || true

    cleanup
    log "Starting 3-node PXC cluster..."
    $COMPOSE up -d

    if ! wait_for_cluster 3 300; then
        err "Cluster failed to form"
        $COMPOSE logs
        cleanup
        exit 1
    fi

    create_test_data
    start_insert_load

    crashed=false
    for attempt in $(seq 1 $MAX_SST_ATTEMPTS); do
        if force_sst_on_node3 "$attempt"; then
            log ""
            log "=========================================="
            log "  PXB-3568 CRASH REPRODUCED (attempt $attempt)"
            log "=========================================="
            log ""
            mkdir -p "$PROJECT_DIR/evidence"
            docker logs lz4-pxc-node1 > "$PROJECT_DIR/evidence/node1-reproduce.log" 2>&1 || true
            docker logs lz4-pxc-node2 > "$PROJECT_DIR/evidence/node2-reproduce.log" 2>&1 || true
            docker logs lz4-pxc-node3 > "$PROJECT_DIR/evidence/node3-reproduce.log" 2>&1 || true
            crashed=true
            break
        fi

        if [ "$attempt" -lt "$MAX_SST_ATTEMPTS" ]; then
            log "Retrying... adding more data between attempts"
            wait_for_node_synced lz4-pxc-node3 120 || true
            sleep 10
        fi
    done

    if [ "$crashed" = false ]; then
        log ""
        log "=========================================="
        log "  CRASH NOT REPRODUCED after $MAX_SST_ATTEMPTS attempts"
        log "=========================================="
        log ""
        log "Try increasing MAX_SST_ATTEMPTS or data volume."
        mkdir -p "$PROJECT_DIR/evidence"
        docker logs lz4-pxc-node1 > "$PROJECT_DIR/evidence/node1-no-crash.log" 2>&1 || true
        docker logs lz4-pxc-node3 > "$PROJECT_DIR/evidence/node3-no-crash.log" 2>&1 || true
    fi

    mkdir -p "$PROJECT_DIR/evidence"
    docker exec lz4-pxc-node1 bash -c "ldd /usr/bin/xtrabackup | grep lz4; rpm -q lz4-libs" \
        > "$PROJECT_DIR/evidence/lz4-version.txt" 2>&1 || true

    cleanup
    log "Done."
}

main "$@"
