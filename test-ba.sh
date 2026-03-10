#!/usr/bin/env bash
# Before/After test for PXB-3568 LZ4 crash
# Starts 3-node cluster, loads data, forces SST with LZ4 to trigger crash
set -euo pipefail

PROJECT="$(cd "$(dirname "$0")" && pwd)"
CD="docker compose -f $PROJECT/reproduce/docker-compose.yml"
MYSQL="mysql -uroot -proot -N"
EVIDENCE="$PROJECT/evidence"

log() { echo "[$(date '+%H:%M:%S')] $*" >&2; }

hard_cleanup() {
    $CD down -v --remove-orphans 2>/dev/null || true
    docker volume rm $(docker volume ls -q | grep reproduce_) 2>/dev/null || true
    sleep 2
}

wait_cluster() {
    local max="${1:-300}" elapsed=0
    while [ $elapsed -lt "$max" ]; do
        for c in lz4-pxc-node1 lz4-pxc-node2 lz4-pxc-node3; do
            local s; s=$(docker exec "$c" $MYSQL -e "SHOW STATUS LIKE 'wsrep_cluster_size'" 2>/dev/null | awk '{print $2}') || continue
            [ "$s" = "3" ] && { log "Cluster ready (${elapsed}s)"; return 0; }
        done
        sleep 5; elapsed=$((elapsed + 5))
    done
    return 1
}

run_phase() {
    local image="$1" label="$2"
    log "=== $label ==="
    hard_cleanup

    log "Starting 3-node cluster with $image..."
    PXC_IMAGE="$image" $CD up -d

    if ! wait_cluster 300; then
        log "Cluster failed to form"
        docker logs lz4-pxc-node1 2>&1 | tail -10
        hard_cleanup
        return 2
    fi

    # Create test data
    docker exec lz4-pxc-node1 $MYSQL -e "
        CREATE DATABASE IF NOT EXISTS pxb3568;
        USE pxb3568;
        CREATE TABLE IF NOT EXISTS testdata (id BIGINT AUTO_INCREMENT PRIMARY KEY, data BLOB, ts TIMESTAMP DEFAULT CURRENT_TIMESTAMP) ENGINE=InnoDB;
    " 2>/dev/null

    # Insert data for 30s in background
    docker exec -d lz4-pxc-node1 bash -c '
        for i in $(seq 1 300); do
            mysql -uroot -proot pxb3568 -e "
                INSERT INTO testdata (data)
                SELECT RANDOM_BYTES(FLOOR(1000 + RAND()*8000))
                FROM (SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5
                      UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9 UNION SELECT 10) t;
            " 2>/dev/null
            sleep 0.1
        done
    '
    log "Loading data for 30s..."
    sleep 30

    # Force SST on node3
    log "Stopping node3 and clearing galera state..."
    docker stop lz4-pxc-node3 2>/dev/null || true
    sleep 5

    local vol; vol=$(docker volume ls -q | grep node3-data | head -1)
    [ -n "$vol" ] && docker run --rm -v "$vol:/d" alpine sh -c "rm -f /d/galera.cache /d/grastate.dat /d/gvwstate.dat" 2>/dev/null || true

    sleep 10
    log "Starting node3 (triggers SST with LZ4)..."
    docker start lz4-pxc-node3

    # Monitor
    local elapsed=0 result="timeout"
    while [ $elapsed -lt 120 ]; do
        # Check donor crash
        for node in lz4-pxc-node1 lz4-pxc-node2; do
            local st; st=$(docker inspect -f '{{.State.Status}}' "$node" 2>/dev/null) || st="?"
            if [ "$st" = "exited" ] || [ "$st" = "dead" ]; then
                if docker logs "$node" 2>&1 | grep -q "signal 6"; then
                    log "Signal 6 CRASH on $node at ${elapsed}s"
                    result="crash"
                    break 2
                fi
            fi
        done

        # Check node3
        local n3st; n3st=$(docker inspect -f '{{.State.Status}}' lz4-pxc-node3 2>/dev/null) || n3st="?"
        if [ "$n3st" = "exited" ] || [ "$n3st" = "dead" ]; then
            if docker logs lz4-pxc-node3 2>&1 | grep -q "signal 6"; then
                log "Signal 6 CRASH on node3 at ${elapsed}s"
                result="crash"
                break
            fi
            log "Node3 exited at ${elapsed}s"
            result="crash"
            break
        fi

        # Check sync
        local state; state=$(docker exec lz4-pxc-node3 $MYSQL -e \
            "SHOW STATUS LIKE 'wsrep_local_state_comment'" 2>/dev/null | awk '{print $2}') || state=""
        if [ "$state" = "Synced" ]; then
            log "Node3 SYNCED at ${elapsed}s"
            result="success"
            break
        fi

        sleep 5; elapsed=$((elapsed + 5))
    done

    mkdir -p "$EVIDENCE"
    docker logs lz4-pxc-node1 > "$EVIDENCE/${label}-node1.log" 2>&1 || true
    docker logs lz4-pxc-node3 > "$EVIDENCE/${label}-node3.log" 2>&1 || true
    hard_cleanup

    log "$label RESULT: $result"
    echo "$result"
}

main() {
    echo ""
    echo "================================================================"
    echo "  PXB-3568: Before/After LZ4 Patch Comparison"
    echo "================================================================"
    echo ""

    mkdir -p "$EVIDENCE"

    before=$(run_phase "percona/percona-xtradb-cluster:8.0.45" "BEFORE")
    sleep 5
    after=$(run_phase "pxc-fix-patched:8.0.45" "AFTER")

    echo ""
    echo "================================================================"
    echo "  BEFORE (stock):   $before"
    echo "  AFTER  (patched): $after"
    echo ""
    if [ "$before" = "crash" ] && [ "$after" = "success" ]; then
        echo "  VERDICT: PASS"
    elif [ "$before" != "crash" ]; then
        echo "  VERDICT: INCONCLUSIVE (no crash in BEFORE)"
    else
        echo "  VERDICT: FAIL"
    fi
    echo "================================================================"
}

main "$@"
