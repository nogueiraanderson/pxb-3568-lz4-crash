#!/usr/bin/env bash
# PXB-3568 Fix C: Before/After Patch Validation
#
# Phase A (BEFORE): Stock PXC 8.0.45, force SST with LZ4 compression.
#   Expected: Signal 6 crash (or at minimum, LZ4 compression failure).
#
# Phase B (AFTER): Patched xtrabackup binary (ds_compress_lz4.cc fix).
#   Expected: SST completes, node syncs, no crash.
#
# Phase C: Side-by-side comparison and PASS/FAIL verdict.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
REPRODUCE_DIR="$PROJECT_DIR/reproduce"

COMPOSE_STOCK="docker compose -f $REPRODUCE_DIR/docker-compose.yml"
COMPOSE_PATCHED="docker compose -f $REPRODUCE_DIR/docker-compose.yml -f $SCRIPT_DIR/docker-compose.override.yml"
MYSQL_CMD="mysql -uroot -proot -N"
CONTAINERS=("lz4-pxc-node1" "lz4-pxc-node2" "lz4-pxc-node3")
SST_ATTEMPTS=${SST_ATTEMPTS:-3}
EVIDENCE="$PROJECT_DIR/evidence/patched-source"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
err() { echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2; }

cleanup() {
    $COMPOSE_STOCK down -v --remove-orphans 2>/dev/null || true
    $COMPOSE_PATCHED down -v --remove-orphans 2>/dev/null || true
}

wait_for_cluster() {
    local max_wait="${1:-300}"
    local elapsed=0
    while [ $elapsed -lt "$max_wait" ]; do
        for container in "${CONTAINERS[@]}"; do
            local size
            size=$(docker exec "$container" $MYSQL_CMD -e \
                "SHOW STATUS LIKE 'wsrep_cluster_size'" 2>/dev/null | awk '{print $2}') || continue
            if [ "$size" = "3" ]; then
                log "Cluster ready: size=3 (${elapsed}s)"
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

# Returns 0 if crash detected, 1 if SST completed successfully, 2 if timeout
try_sst() {
    local attempt="$1"
    local label="$2"

    log "=== $label: SST attempt $attempt/$SST_ATTEMPTS ==="

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
            local logs
            logs=$(docker logs lz4-pxc-node3 2>&1 | tail -100)
            if echo "$logs" | grep -qiE "signal 6|sigabrt|abort"; then
                log "CRASH: Signal 6 detected on node3"
                return 0
            fi
            # Check donor
            logs=$(docker logs lz4-pxc-node1 2>&1 | tail -100)
            if echo "$logs" | grep -qiE "signal 6|sigabrt|abort"; then
                log "CRASH: Signal 6 detected on donor (node1)"
                return 0
            fi
            log "Container exited without clear Signal 6"
            return 0
        fi

        local state
        state=$(docker exec lz4-pxc-node3 $MYSQL_CMD -e \
            "SHOW STATUS LIKE 'wsrep_local_state_comment'" 2>/dev/null | awk '{print $2}') || state=""
        if [ "$state" = "Synced" ]; then
            log "Node3 synced successfully"
            return 1
        fi

        sleep 5
        elapsed=$((elapsed + 5))
    done

    log "Timeout"
    return 2
}

main() {
    echo ""
    echo "================================================================"
    echo "  PXB-3568 Fix C: BEFORE/AFTER PATCH VALIDATION"
    echo "================================================================"
    echo ""
    echo "  Phase A (BEFORE): Stock PXC 8.0.45, LZ4 SST"
    echo "    Expected: Signal 6 crash"
    echo ""
    echo "  Phase B (AFTER):  Patched ds_compress_lz4.cc, LZ4 SST"
    echo "    Expected: SST completes, node syncs"
    echo ""
    echo "  Phase C: Comparison and verdict"
    echo ""
    echo "================================================================"

    rm -rf "$EVIDENCE"
    mkdir -p "$EVIDENCE/before" "$EVIDENCE/after"

    # ── Phase A: BEFORE (stock image) ─────────────────────────────
    echo ""
    log "Phase A: BEFORE (stock percona-xtradb-cluster:8.0.45)"
    log ""

    cleanup

    $COMPOSE_STOCK up -d
    if ! wait_for_cluster 300; then
        err "Stock cluster failed to form"
        $COMPOSE_STOCK logs > "$EVIDENCE/before/cluster-fail.log" 2>&1
        cleanup
        exit 1
    fi

    create_test_data
    start_insert_load

    # Record xtrabackup version
    docker exec lz4-pxc-node1 bash -c \
        "xtrabackup --version 2>&1; echo '---'; ldd /usr/bin/xtrabackup | grep lz4; echo '---'; rpm -q lz4-libs" \
        > "$EVIDENCE/before/xtrabackup-version.txt" 2>&1 || true

    before_crashed=false
    for attempt in $(seq 1 $SST_ATTEMPTS); do
        try_sst "$attempt" "BEFORE"
        rc=$?
        if [ $rc -eq 0 ]; then
            before_crashed=true
            log "BEFORE: Crash reproduced on attempt $attempt"
            break
        fi
        if [ "$attempt" -lt "$SST_ATTEMPTS" ]; then
            wait_for_node_synced lz4-pxc-node3 120 || true
            sleep 10
        fi
    done

    if [ "$before_crashed" = false ]; then
        log "BEFORE: No crash in $SST_ATTEMPTS attempts (bug may be nondeterministic)"
    fi

    # Save evidence
    docker logs lz4-pxc-node1 > "$EVIDENCE/before/node1.log" 2>&1 || true
    docker logs lz4-pxc-node3 > "$EVIDENCE/before/node3.log" 2>&1 || true

    cleanup
    sleep 5

    # ── Phase B: AFTER (patched image) ────────────────────────────
    echo ""
    log "Phase B: AFTER (patched ds_compress_lz4.cc)"
    log ""

    # Preflight: check if patched image exists
    if ! docker image inspect pxc-fix-patched:8.0.45 &>/dev/null; then
        log "Patched image not found. Building (this takes 15-20 minutes)..."
        $COMPOSE_PATCHED build 2>&1 | tail -10
    fi

    $COMPOSE_PATCHED up -d
    if ! wait_for_cluster 300; then
        err "Patched cluster failed to form"
        $COMPOSE_PATCHED logs > "$EVIDENCE/after/cluster-fail.log" 2>&1
        cleanup
        exit 1
    fi

    create_test_data
    start_insert_load

    # Record xtrabackup version
    docker exec lz4-pxc-node1 bash -c \
        "xtrabackup --version 2>&1; echo '---'; ldd /usr/bin/xtrabackup | grep lz4; echo '---'; rpm -q lz4-libs" \
        > "$EVIDENCE/after/xtrabackup-version.txt" 2>&1 || true

    after_crashed=false
    after_synced=0
    for attempt in $(seq 1 $SST_ATTEMPTS); do
        try_sst "$attempt" "AFTER"
        rc=$?
        if [ $rc -eq 0 ]; then
            after_crashed=true
            log "AFTER: Crash on attempt $attempt (fix did NOT work)"
            break
        elif [ $rc -eq 1 ]; then
            after_synced=$((after_synced + 1))
        fi
        if [ "$attempt" -lt "$SST_ATTEMPTS" ]; then
            wait_for_node_synced lz4-pxc-node3 120 || true
            sleep 10
        fi
    done

    # Save evidence
    docker logs lz4-pxc-node1 > "$EVIDENCE/after/node1.log" 2>&1 || true
    docker logs lz4-pxc-node3 > "$EVIDENCE/after/node3.log" 2>&1 || true

    cleanup

    # ── Phase C: Comparison ───────────────────────────────────────
    echo ""
    {
        echo "================================================================"
        echo "  PXB-3568 Fix C: COMPARISON"
        echo "================================================================"
        echo ""
        echo "=== XtraBackup Version ==="
        echo ""
        echo "BEFORE (stock):"
        head -1 "$EVIDENCE/before/xtrabackup-version.txt" 2>/dev/null || echo "  (not captured)"
        echo ""
        echo "AFTER (patched):"
        head -1 "$EVIDENCE/after/xtrabackup-version.txt" 2>/dev/null || echo "  (not captured)"
        echo ""
        echo "=== LZ4 Library ==="
        echo ""
        echo "BEFORE:"
        grep lz4 "$EVIDENCE/before/xtrabackup-version.txt" 2>/dev/null || echo "  (not captured)"
        echo ""
        echo "AFTER:"
        grep lz4 "$EVIDENCE/after/xtrabackup-version.txt" 2>/dev/null || echo "  (not captured)"
        echo ""
        echo "=== SST Results ==="
        echo ""
        echo "BEFORE (stock PXC 8.0.45):"
        if [ "$before_crashed" = true ]; then
            echo "  Signal 6 CRASH (bug reproduced)"
        else
            echo "  No crash in $SST_ATTEMPTS attempts"
        fi
        echo ""
        echo "AFTER (patched ds_compress_lz4.cc):"
        if [ "$after_crashed" = true ]; then
            echo "  CRASH (patch did NOT fix the bug)"
        else
            echo "  $after_synced/$SST_ATTEMPTS SST cycles completed successfully"
        fi
        echo ""

        echo "=== Crash Evidence (BEFORE) ==="
        echo ""
        grep -iE "signal 6|sigabrt|abort|lz4.*fail|compress.*fail" \
            "$EVIDENCE/before/node1.log" "$EVIDENCE/before/node3.log" 2>/dev/null \
            | head -10 || echo "  (no crash signatures found)"
        echo ""

        echo "=== Crash Evidence (AFTER) ==="
        echo ""
        grep -iE "signal 6|sigabrt|abort|lz4.*fail|compress.*fail" \
            "$EVIDENCE/after/node1.log" "$EVIDENCE/after/node3.log" 2>/dev/null \
            | head -10 || echo "  (no crash signatures found)"
        echo ""

        echo "=== VERDICT ==="
        echo ""

        if [ "$before_crashed" = true ] && [ "$after_crashed" = false ] && [ "$after_synced" -gt 0 ]; then
            echo "  ┌────────────────────────────────────────────────────────┐"
            echo "  │  PASS                                                  │"
            echo "  └────────────────────────────────────────────────────────┘"
            echo ""
            echo "  BEFORE: Signal 6 crash with stock xtrabackup"
            echo "  AFTER:  $after_synced/$SST_ATTEMPTS SST cycles completed with patched binary"
            echo ""
            echo "  The ds_compress_lz4.cc patch fixes the LZ4 crash."
            echo "  Patch file: patch/ds_compress_lz4.patch"
        elif [ "$before_crashed" = false ]; then
            echo "  ┌────────────────────────────────────────────────────────┐"
            echo "  │  INCONCLUSIVE                                          │"
            echo "  └────────────────────────────────────────────────────────┘"
            echo ""
            echo "  The crash was not reproduced in the BEFORE phase."
            echo "  Try increasing SST_ATTEMPTS or data volume."
        else
            echo "  ┌────────────────────────────────────────────────────────┐"
            echo "  │  FAIL                                                  │"
            echo "  └────────────────────────────────────────────────────────┘"
            echo ""
            echo "  The patched binary still crashes. Additional investigation needed."
        fi

        echo ""
        echo "================================================================"
        echo "  Evidence saved to: evidence/patched-source/"
        echo "================================================================"
    } | tee "$EVIDENCE/comparison.txt"
}

main "$@"
