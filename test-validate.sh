#!/usr/bin/env bash
# PXB-3568: Direct xtrabackup LZ4 crash validation
# Tests xtrabackup --backup with different compression methods
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE="docker compose -f $PROJECT_DIR/reproduce/docker-compose.yml"
MYSQL="mysql -uroot -proot -N"
XB="/usr/bin/pxc_extra/pxb-8.0/bin/xtrabackup"
IMAGE="${1:-percona/percona-xtradb-cluster:8.0.45}"
EVIDENCE="$PROJECT_DIR/evidence"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

full_cleanup() {
    $COMPOSE down -v --remove-orphans 2>/dev/null || true
    for v in $(docker volume ls -q 2>/dev/null | grep reproduce_ || true); do
        docker volume rm "$v" 2>/dev/null || true
    done
    sleep 2
}

log "=== PXB-3568 Validation ==="
log "Image: $IMAGE"

full_cleanup

log "Starting node1..."
PXC_IMAGE="$IMAGE" $COMPOSE up -d pxc-node1

# Wait for full PXC bootstrap (init cycle + real start)
log "Waiting for PXC bootstrap (up to 120s)..."
sleep 20
for i in $(seq 1 34); do
    if docker exec lz4-pxc-node1 $MYSQL -e "SELECT 1" &>/dev/null; then
        ready=$(docker exec lz4-pxc-node1 $MYSQL -e "SHOW STATUS LIKE 'wsrep_ready'" 2>/dev/null | awk '{print $2}') || ready=""
        if [ "$ready" = "ON" ]; then
            log "Node1 ready"
            break
        fi
    fi
    sleep 3
done

# Version info
log "XtraBackup version:"
docker exec lz4-pxc-node1 bash -c "$XB --version 2>&1 | head -1" || true
docker exec lz4-pxc-node1 bash -c "rpm -q lz4-libs 2>/dev/null || ls -la /usr/lib64/liblz4.so.1" || true

# Load test data (~30MB of random binary)
log "Loading test data..."
docker exec lz4-pxc-node1 $MYSQL -e "CREATE DATABASE IF NOT EXISTS pxb3568" 2>/dev/null
docker exec lz4-pxc-node1 $MYSQL pxb3568 -e "
    CREATE TABLE IF NOT EXISTS t (id INT AUTO_INCREMENT PRIMARY KEY, data BLOB) ENGINE=InnoDB" 2>/dev/null

for batch in $(seq 1 10); do
    docker exec lz4-pxc-node1 $MYSQL pxb3568 -e "
        INSERT INTO t (data)
        SELECT UNHEX(REPEAT(SHA2(RAND(),256), 2000))
        FROM (SELECT 1 a UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5
              UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9 UNION SELECT 10) t1
        CROSS JOIN (SELECT 1 b UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5) t2;
    " 2>/dev/null
done

row_count=$(docker exec lz4-pxc-node1 $MYSQL -e "SELECT COUNT(*) FROM pxb3568.t" 2>/dev/null | tr -d ' ')
data_mb=$(docker exec lz4-pxc-node1 $MYSQL -e "SELECT ROUND(SUM(LENGTH(data))/1024/1024,1) FROM pxb3568.t" 2>/dev/null | tr -d ' ')
log "Loaded $row_count rows (~${data_mb}MB)"

mkdir -p "$EVIDENCE"

# Test 1: LZ4 compression (expected: CRASH)
log "Test 1: xtrabackup --backup --compress=lz4 --compress-chunk-size=65534"
lz4_output=$(docker exec lz4-pxc-node1 bash -c "
    rm -rf /tmp/backup-lz4 && mkdir -p /tmp/backup-lz4
    $XB --backup --user=root --password=root \
        --compress=lz4 --compress-chunk-size=65534 \
        --target-dir=/tmp/backup-lz4 --no-server-version-check 2>&1
    echo EXIT_STATUS=\$?
" 2>&1)
if echo "$lz4_output" | grep -q "terribly wrong\|signal 6\|abort"; then
    log "  RESULT: CRASH (Signal 6) as expected"
    lz4_result="crash"
else
    log "  RESULT: SUCCESS (no crash)"
    lz4_result="success"
fi
echo "$lz4_output" > "$EVIDENCE/lz4-backup.log"

# Test 2: zstd compression (expected: SUCCESS)
log "Test 2: xtrabackup --backup --compress=zstd"
zstd_output=$(docker exec lz4-pxc-node1 bash -c "
    rm -rf /tmp/backup-zstd && mkdir -p /tmp/backup-zstd
    $XB --defaults-file=/dev/null --datadir=/var/lib/mysql --socket=/tmp/mysql.sock \
        --backup --user=root --password=root \
        --compress=zstd \
        --target-dir=/tmp/backup-zstd --no-server-version-check 2>&1
    echo EXIT_STATUS=\$?
" 2>&1)
if echo "$zstd_output" | grep -q "completed OK"; then
    log "  RESULT: SUCCESS (completed OK)"
    zstd_result="success"
else
    log "  RESULT: FAILED"
    zstd_result="failed"
fi
echo "$zstd_output" > "$EVIDENCE/zstd-backup.log"

# Test 3: No compression (expected: SUCCESS)
log "Test 3: xtrabackup --backup (no compression)"
none_output=$(docker exec lz4-pxc-node1 bash -c "
    rm -rf /tmp/backup-none && mkdir -p /tmp/backup-none
    $XB --defaults-file=/dev/null --datadir=/var/lib/mysql --socket=/tmp/mysql.sock \
        --backup --user=root --password=root \
        --target-dir=/tmp/backup-none --no-server-version-check 2>&1
    echo EXIT_STATUS=\$?
" 2>&1)
if echo "$none_output" | grep -q "completed OK"; then
    log "  RESULT: SUCCESS (completed OK)"
    none_result="success"
else
    log "  RESULT: FAILED"
    none_result="failed"
fi
echo "$none_output" > "$EVIDENCE/none-backup.log"

full_cleanup

echo ""
echo "================================================================"
echo "  PXB-3568 Validation Results"
echo "  Image: $IMAGE"
echo "  Data: ${row_count:-0} rows (~${data_mb:-0}MB)"
echo "================================================================"
echo ""
echo "  compress=lz4 (chunk=65534): $lz4_result"
echo "  compress=zstd:              $zstd_result"
echo "  no compression:             $none_result"
echo ""
if [ "$lz4_result" = "crash" ] && [ "$zstd_result" = "success" ]; then
    echo "  VERDICT: CONFIRMED - LZ4 crashes, zstd works"
elif [ "$lz4_result" = "crash" ]; then
    echo "  VERDICT: LZ4 crash confirmed, zstd also failed"
else
    echo "  VERDICT: LZ4 crash NOT reproduced"
fi
echo ""
echo "  Evidence: $EVIDENCE/"
echo "================================================================"
