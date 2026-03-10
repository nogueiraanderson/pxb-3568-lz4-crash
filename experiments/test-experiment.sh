#!/usr/bin/env bash
# Test an experiment image for the PXB-3568 LZ4 crash.
# Usage: ./test-experiment.sh <image-name> <experiment-label>
# Example: ./test-experiment.sh pxb-exp-gcc11-nolto:8.0.45 "GCC11+LTO_OFF"
set -euo pipefail

IMAGE="${1:?Usage: $0 <image> <label>}"
LABEL="${2:?Usage: $0 <image> <label>}"
CONTAINER="pxb-exp-${LABEL//[^a-zA-Z0-9]/-}"
MYSQL="mysql -uroot -proot -N"
XB="/usr/bin/pxc_extra/pxb-8.0/bin/xtrabackup"
EVIDENCE_DIR="$(cd "$(dirname "$0")/.." && pwd)/evidence/experiments"

log() { echo "[$(date '+%H:%M:%S')] [$LABEL] $*"; }

cleanup() {
    docker rm -f "$CONTAINER" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$EVIDENCE_DIR"

log "Starting container from $IMAGE..."
docker run -d --name "$CONTAINER" --privileged \
    -e MYSQL_ROOT_PASSWORD=root \
    -e CLUSTER_NAME=exp-test \
    -e "CLUSTER_JOIN=" \
    "$IMAGE" mysqld \
    --pxc_encrypt_cluster_traffic=OFF \
    --innodb_buffer_pool_size=256M \
    --innodb_log_file_size=128M \
    --innodb_flush_log_at_trx_commit=0

# Wait for MySQL ready
log "Waiting for MySQL (up to 120s)..."
for i in $(seq 1 40); do
    if docker exec "$CONTAINER" $MYSQL -e "SELECT 1" &>/dev/null; then
        ready=$(docker exec "$CONTAINER" $MYSQL -e "SHOW STATUS LIKE 'wsrep_ready'" 2>/dev/null | awk '{print $2}') || ready=""
        if [ "$ready" = "ON" ]; then
            log "MySQL ready"
            break
        fi
    fi
    sleep 3
done

# Version info
log "XtraBackup version:"
docker exec "$CONTAINER" bash -c "$XB --version 2>&1 | head -1" || true

# Check for LTO symbols
log "LTO check:"
docker exec "$CONTAINER" bash -c "nm $XB 2>/dev/null | grep -c lto_priv || echo 'no nm or no lto_priv'" || true

# Load test data
log "Loading test data (~30MB random binary)..."
docker exec "$CONTAINER" $MYSQL -e "CREATE DATABASE IF NOT EXISTS pxb3568" 2>/dev/null
docker exec "$CONTAINER" $MYSQL pxb3568 -e "
    CREATE TABLE IF NOT EXISTS t (id INT AUTO_INCREMENT PRIMARY KEY, data BLOB) ENGINE=InnoDB" 2>/dev/null

for batch in $(seq 1 10); do
    docker exec "$CONTAINER" $MYSQL pxb3568 -e "
        INSERT INTO t (data)
        SELECT UNHEX(REPEAT(SHA2(RAND(),256), 2000))
        FROM (SELECT 1 a UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5
              UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9 UNION SELECT 10) t1
        CROSS JOIN (SELECT 1 b UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5) t2;
    " 2>/dev/null
done

row_count=$(docker exec "$CONTAINER" $MYSQL -e "SELECT COUNT(*) FROM pxb3568.t" 2>/dev/null | tr -d ' ')
log "Loaded $row_count rows"

# Start concurrent INSERT workload
log "Starting concurrent writes..."
for i in $(seq 1 30); do
    docker exec "$CONTAINER" $MYSQL pxb3568 -e "
        INSERT INTO t (data)
        SELECT UNHEX(REPEAT(SHA2(RAND(),256), 2000))
        FROM (SELECT 1 a UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5
              UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9 UNION SELECT 10) t1
        CROSS JOIN (SELECT 1 b UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5) t2;
    " 2>/dev/null &
done

# Test LZ4 backup
log "Running: xtrabackup --backup --compress=lz4 --compress-chunk-size=65534"
lz4_output=$(docker exec "$CONTAINER" bash -c "
    rm -rf /tmp/backup-lz4 && mkdir -p /tmp/backup-lz4
    $XB --backup --user=root --password=root \
        --compress=lz4 --compress-chunk-size=65534 \
        --target-dir=/tmp/backup-lz4 --no-server-version-check 2>&1
    echo EXIT_STATUS=\$?
" 2>&1)

wait

if echo "$lz4_output" | grep -q "completed OK"; then
    result="SUCCESS"
    log "RESULT: SUCCESS (completed OK)"
elif echo "$lz4_output" | grep -qE "terribly wrong|Fatal signal"; then
    result="CRASH"
    log "RESULT: CRASH (Signal 6)"
elif echo "$lz4_output" | grep -q "EXIT_STATUS="; then
    exit_code=$(echo "$lz4_output" | grep "EXIT_STATUS=" | tail -1 | cut -d= -f2)
    if [ "$exit_code" = "0" ]; then
        result="SUCCESS"
        log "RESULT: SUCCESS (exit 0, no 'completed OK' banner)"
    else
        result="FAIL"
        log "RESULT: FAIL (exit code $exit_code)"
    fi
else
    result="UNKNOWN"
    log "RESULT: UNKNOWN"
fi

echo "$lz4_output" > "$EVIDENCE_DIR/${LABEL}.log"

echo ""
echo "================================================================"
echo "  Experiment: $LABEL"
echo "  Image:      $IMAGE"
echo "  LZ4 backup: $result"
echo "================================================================"
echo ""
