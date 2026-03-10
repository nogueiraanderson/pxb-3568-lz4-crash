#!/usr/bin/env bash
# Manual before/after test for PXB-3568 LZ4 crash
# Loads heavy random data, then forces SST to trigger LZ4 compression
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE="docker compose -f $PROJECT_DIR/reproduce/docker-compose.yml"
MYSQL="mysql -uroot -proot -N"
EVIDENCE="$PROJECT_DIR/evidence"
IMAGE="${1:-percona/percona-xtradb-cluster:8.0.45}"
LABEL="${2:-STOCK}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

cleanup() {
    log "Cleaning up..."
    $COMPOSE down -v --remove-orphans 2>/dev/null || true
}
trap cleanup EXIT

wait_mysql() {
    local container="$1" max="${2:-180}" elapsed=0
    while [ $elapsed -lt "$max" ]; do
        if docker exec "$container" $MYSQL -e "SELECT 1" &>/dev/null; then
            return 0
        fi
        sleep 3
        elapsed=$((elapsed + 3))
    done
    return 1
}

cleanup
log "=== $LABEL: Starting node1 ==="

PXC_IMAGE="$IMAGE" $COMPOSE up -d pxc-node1
log "Waiting for node1..."
if ! wait_mysql lz4-pxc-node1 180; then
    log "FAIL: node1 didn't start"
    docker logs lz4-pxc-node1 2>&1 | tail -20
    exit 1
fi

# Create and load heavy test data
log "Creating database and loading data..."
docker exec lz4-pxc-node1 $MYSQL -e "
    CREATE DATABASE IF NOT EXISTS pxb3568;
    USE pxb3568;
    CREATE TABLE testdata (
        id INT AUTO_INCREMENT PRIMARY KEY,
        data BLOB
    ) ENGINE=InnoDB;
" 2>/dev/null

# Insert ~200MB of random data to ensure LZ4 compression hits boundary conditions
# Each row is ~65000 bytes (close to the 65534 chunk size)
log "Inserting ~200MB of random data (takes ~60s)..."
for batch in $(seq 1 20); do
    docker exec lz4-pxc-node1 $MYSQL -e "
        INSERT INTO pxb3568.testdata (data)
        SELECT RANDOM_BYTES(FLOOR(60000 + RAND()*5534))
        FROM (SELECT 1 a UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5
              UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9 UNION SELECT 10) t1
        CROSS JOIN (SELECT 1 b UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5
              UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9 UNION SELECT 10) t2;
    " 2>/dev/null || log "Insert batch $batch failed (ok if partial)"
    [ $((batch % 5)) -eq 0 ] && log "  Batch $batch/20 done"
done

row_count=$(docker exec lz4-pxc-node1 $MYSQL -e "SELECT COUNT(*) FROM pxb3568.testdata" 2>/dev/null | tr -d ' ')
data_mb=$(docker exec lz4-pxc-node1 $MYSQL -e "SELECT ROUND(SUM(LENGTH(data))/1024/1024) FROM pxb3568.testdata" 2>/dev/null | tr -d ' ')
log "Loaded $row_count rows (~${data_mb}MB)"

# Save xtrabackup version
docker exec lz4-pxc-node1 bash -c "/usr/bin/pxc_extra/pxb-8.0/bin/xtrabackup --version 2>&1; echo '---'; ldd /usr/bin/pxc_extra/pxb-8.0/bin/xtrabackup | grep lz4; echo '---'; rpm -q lz4-libs" \
    > "$EVIDENCE/${LABEL}-version.txt" 2>&1 || true

# Now start node2 to trigger SST with LZ4 compression of all this data
log "Starting node2 (will trigger SST with LZ4 compression)..."
PXC_IMAGE="$IMAGE" $COMPOSE up -d pxc-node2

# Monitor for crash or success
log "Monitoring SST (up to 300s)..."
elapsed=0
result="timeout"
while [ $elapsed -lt 300 ]; do
    # Check node1 (donor)
    n1_status=$(docker inspect -f '{{.State.Status}}' lz4-pxc-node1 2>/dev/null) || n1_status="unknown"
    if [ "$n1_status" = "exited" ] || [ "$n1_status" = "dead" ]; then
        if docker logs lz4-pxc-node1 2>&1 | grep -qiE "signal 6|sigabrt"; then
            log "CRASH: Signal 6 on donor (node1) at ${elapsed}s"
            result="crash"
            break
        fi
        log "Node1 exited without Signal 6 at ${elapsed}s"
        result="crash"
        break
    fi

    # Check node2 (joiner)
    n2_status=$(docker inspect -f '{{.State.Status}}' lz4-pxc-node2 2>/dev/null) || n2_status="unknown"
    if [ "$n2_status" = "exited" ] || [ "$n2_status" = "dead" ]; then
        if docker logs lz4-pxc-node2 2>&1 | grep -qiE "signal 6|sigabrt"; then
            log "CRASH: Signal 6 on joiner (node2) at ${elapsed}s"
            result="crash"
            break
        fi
    fi

    # Check if node2 synced
    state=$(docker exec lz4-pxc-node2 $MYSQL -e \
        "SHOW STATUS LIKE 'wsrep_local_state_comment'" 2>/dev/null | awk '{print $2}') || state=""
    if [ "$state" = "Synced" ]; then
        size=$(docker exec lz4-pxc-node1 $MYSQL -e \
            "SHOW STATUS LIKE 'wsrep_cluster_size'" 2>/dev/null | awk '{print $2}') || size=""
        log "SUCCESS: Node2 synced, cluster_size=$size at ${elapsed}s"
        result="success"
        break
    fi

    sleep 5
    elapsed=$((elapsed + 5))
done

# Save evidence
mkdir -p "$EVIDENCE"
docker logs lz4-pxc-node1 > "$EVIDENCE/${LABEL}-node1.log" 2>&1 || true
docker logs lz4-pxc-node2 > "$EVIDENCE/${LABEL}-node2.log" 2>&1 || true

echo ""
echo "================================================================"
echo "  $LABEL RESULT: $result"
echo "  Image: $IMAGE"
echo "  Data: $row_count rows (~${data_mb}MB)"
echo "  Evidence: $EVIDENCE/${LABEL}-*.log"
echo "================================================================"

# Exit codes: 0=crash, 1=success, 2=timeout
case "$result" in
    crash)   exit 0 ;;
    success) exit 1 ;;
    *)       exit 2 ;;
esac
