#!/usr/bin/env bash
# Quick before/after test for PXB-3568 LZ4 crash
# Runs a 2-node cluster (simpler than 3-node) and forces SST with LZ4
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE="docker compose -f $PROJECT_DIR/reproduce/docker-compose.yml"
MYSQL="mysql -uroot -proot -N"
EVIDENCE="$PROJECT_DIR/evidence"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

cleanup() {
    log "Cleaning up..."
    $COMPOSE down -v --remove-orphans 2>/dev/null || true
}
trap cleanup EXIT

wait_mysql() {
    local container="$1" max="${2:-120}" elapsed=0
    while [ $elapsed -lt "$max" ]; do
        if docker exec "$container" $MYSQL -e "SELECT 1" &>/dev/null; then
            return 0
        fi
        sleep 3
        elapsed=$((elapsed + 3))
    done
    return 1
}

wait_synced() {
    local container="$1" max="${2:-180}" elapsed=0
    while [ $elapsed -lt "$max" ]; do
        local state
        state=$(docker exec "$container" $MYSQL -e \
            "SHOW STATUS LIKE 'wsrep_local_state_comment'" 2>/dev/null | awk '{print $2}') || true
        if [ "$state" = "Synced" ]; then
            log "$container synced (${elapsed}s)"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    return 1
}

run_test() {
    local image_override="$1"
    local label="$2"

    log "=== $label ==="
    cleanup

    if [ -n "$image_override" ]; then
        PXC_IMAGE="$image_override" $COMPOSE up -d pxc-node1 pxc-node2
    else
        $COMPOSE up -d pxc-node1 pxc-node2
    fi

    log "Waiting for node1..."
    if ! wait_mysql lz4-pxc-node1 180; then
        log "FAIL: node1 didn't start"
        docker logs lz4-pxc-node1 2>&1 | tail -30
        return 2
    fi

    log "Waiting for node2 to sync..."
    if ! wait_synced lz4-pxc-node2 180; then
        log "FAIL: node2 didn't sync"
        docker logs lz4-pxc-node2 2>&1 | tail -30
        return 2
    fi

    # Create test data with incompressible (random) content near 64KB chunks
    log "Loading test data (incompressible blobs)..."
    docker exec lz4-pxc-node1 $MYSQL -e "
        CREATE DATABASE IF NOT EXISTS pxb3568;
        USE pxb3568;
        DROP TABLE IF EXISTS testdata;
        CREATE TABLE testdata (
            id INT AUTO_INCREMENT PRIMARY KEY,
            data BLOB
        ) ENGINE=InnoDB;
    " 2>/dev/null

    # Insert ~50MB of random data in batches
    for i in $(seq 1 50); do
        docker exec lz4-pxc-node1 $MYSQL -e "
            INSERT INTO pxb3568.testdata (data)
            SELECT RANDOM_BYTES(65000) FROM
                (SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5
                 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9 UNION SELECT 10) t;
        " 2>/dev/null || true
    done

    local row_count
    row_count=$(docker exec lz4-pxc-node1 $MYSQL -e "SELECT COUNT(*) FROM pxb3568.testdata" 2>/dev/null | tr -d ' ')
    log "Loaded $row_count rows"

    # Force SST on node2: stop, clear galera state, restart
    log "Forcing SST on node2..."
    docker stop lz4-pxc-node2 2>/dev/null || true
    sleep 3

    # Get the volume name for node2
    local vol
    vol=$(docker volume ls --format '{{.Name}}' | grep node2-data | head -1)
    if [ -n "$vol" ]; then
        docker run --rm -v "$vol:/data" alpine \
            sh -c "rm -f /data/galera.cache /data/grastate.dat /data/gvwstate.dat" 2>/dev/null || true
    fi

    sleep 5
    docker start lz4-pxc-node2

    # Wait and check for crash vs success
    log "Waiting for SST result (up to 120s)..."
    local elapsed=0
    while [ $elapsed -lt 120 ]; do
        local status
        status=$(docker inspect -f '{{.State.Status}}' lz4-pxc-node2 2>/dev/null) || status="unknown"

        if [ "$status" = "exited" ] || [ "$status" = "dead" ]; then
            log "Node2 exited (status=$status)"
            # Check donor (node1) too
            local d_status
            d_status=$(docker inspect -f '{{.State.Status}}' lz4-pxc-node1 2>/dev/null) || d_status="unknown"

            if [ "$d_status" = "exited" ] || [ "$d_status" = "dead" ]; then
                local crash_sig
                crash_sig=$(docker logs lz4-pxc-node1 2>&1 | grep -c "signal 6\|SIGABRT\|abort" || true)
                if [ "$crash_sig" -gt 0 ]; then
                    log "CRASH: Signal 6 on donor (node1)"
                    docker logs lz4-pxc-node1 2>&1 | grep -iE "signal 6|abort|compress|lz4" | tail -5
                    return 0  # crash detected
                fi
            fi

            local crash_sig2
            crash_sig2=$(docker logs lz4-pxc-node2 2>&1 | grep -c "signal 6\|SIGABRT\|abort" || true)
            if [ "$crash_sig2" -gt 0 ]; then
                log "CRASH: Signal 6 on node2"
                return 0
            fi

            log "Container exited without Signal 6"
            docker logs lz4-pxc-node1 2>&1 | tail -10
            return 0  # treat any exit as crash
        fi

        # Check if node2 synced
        local state
        state=$(docker exec lz4-pxc-node2 $MYSQL -e \
            "SHOW STATUS LIKE 'wsrep_local_state_comment'" 2>/dev/null | awk '{print $2}') || state=""
        if [ "$state" = "Synced" ]; then
            log "SUCCESS: Node2 synced after SST"
            return 1  # success
        fi

        sleep 5
        elapsed=$((elapsed + 5))
    done

    log "TIMEOUT: SST did not complete in 120s"
    return 2
}

main() {
    echo ""
    echo "================================================================"
    echo "  PXB-3568: Quick Before/After LZ4 Patch Test"
    echo "================================================================"
    echo ""

    mkdir -p "$EVIDENCE"

    # Phase A: BEFORE (stock PXC 8.0.45)
    run_test "" "BEFORE (stock PXC 8.0.45)"
    before_rc=$?

    # Save before evidence
    docker logs lz4-pxc-node1 > "$EVIDENCE/before-node1.log" 2>&1 || true
    docker logs lz4-pxc-node2 > "$EVIDENCE/before-node2.log" 2>&1 || true
    cleanup

    sleep 5

    # Phase B: AFTER (patched PXC)
    run_test "pxc-fix-patched:8.0.45" "AFTER (patched xtrabackup)"
    after_rc=$?

    # Save after evidence
    docker logs lz4-pxc-node1 > "$EVIDENCE/after-node1.log" 2>&1 || true
    docker logs lz4-pxc-node2 > "$EVIDENCE/after-node2.log" 2>&1 || true

    echo ""
    echo "================================================================"
    echo "  RESULTS"
    echo "================================================================"
    echo ""
    echo "  BEFORE (stock):   $([ $before_rc -eq 0 ] && echo 'CRASH (expected)' || echo 'NO CRASH')"
    echo "  AFTER  (patched): $([ $after_rc -eq 1 ] && echo 'SST SUCCESS (expected)' || echo 'CRASH or TIMEOUT')"
    echo ""

    if [ $before_rc -eq 0 ] && [ $after_rc -eq 1 ]; then
        echo "  VERDICT: PASS - Patch fixes the LZ4 crash"
    elif [ $before_rc -ne 0 ]; then
        echo "  VERDICT: INCONCLUSIVE - Crash not reproduced in BEFORE phase"
    else
        echo "  VERDICT: FAIL - Patch did not fix the crash"
    fi
    echo ""
    echo "  Evidence: $EVIDENCE/"
    echo "================================================================"
}

main "$@"
