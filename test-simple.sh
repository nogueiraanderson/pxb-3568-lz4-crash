#!/usr/bin/env bash
# Simplified single-run test for PXB-3568 LZ4 crash
# Usage: test-simple.sh [IMAGE] [LABEL]
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE="docker compose -f $PROJECT_DIR/reproduce/docker-compose.yml"
MYSQL="mysql -uroot -proot -N"
EVIDENCE="$PROJECT_DIR/evidence"
IMAGE="${1:-percona/percona-xtradb-cluster:8.0.45}"
LABEL="${2:-test}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# Hard cleanup: remove containers, volumes, networks
log "Hard cleanup..."
$COMPOSE down -v --remove-orphans 2>/dev/null || true
docker volume rm reproduce_node1-data reproduce_node2-data reproduce_node3-data \
    reproduce_node1-logs reproduce_node2-logs reproduce_node3-logs 2>/dev/null || true
sleep 2

# Start only node1 as bootstrap
log "Starting node1 with image: $IMAGE"
PXC_IMAGE="$IMAGE" $COMPOSE up -d pxc-node1

log "Waiting for node1 MySQL (up to 120s)..."
elapsed=0
while [ $elapsed -lt 120 ]; do
    if docker exec lz4-pxc-node1 $MYSQL -e "SELECT 1" &>/dev/null; then
        log "Node1 ready (${elapsed}s)"
        break
    fi
    sleep 3
    elapsed=$((elapsed + 3))
done

if [ $elapsed -ge 120 ]; then
    log "FAIL: node1 didn't start"
    docker logs lz4-pxc-node1 2>&1 | tail -20
    $COMPOSE down -v 2>/dev/null || true
    exit 2
fi

# Record xtrabackup info
log "XtraBackup version:"
docker exec lz4-pxc-node1 bash -c "/usr/bin/pxc_extra/pxb-8.0/bin/xtrabackup --version 2>&1 | head -1" || true
docker exec lz4-pxc-node1 bash -c "rpm -q lz4-libs 2>/dev/null || readlink /usr/lib64/liblz4.so.1" || true

# Start node2 (triggers SST with LZ4 compression)
log "Starting node2 (triggers SST)..."
PXC_IMAGE="$IMAGE" $COMPOSE up -d pxc-node2

# Monitor
log "Monitoring (up to 180s)..."
elapsed=0
result="timeout"
while [ $elapsed -lt 180 ]; do
    # Check donor (node1) for crash
    n1=$(docker inspect -f '{{.State.Status}}' lz4-pxc-node1 2>/dev/null) || n1="gone"
    if [ "$n1" = "exited" ] || [ "$n1" = "dead" ]; then
        sig6=$(docker logs lz4-pxc-node1 2>&1 | grep -c "signal 6" || true)
        if [ "$sig6" -gt 0 ]; then
            log "DONOR CRASH: Signal 6 at ${elapsed}s"
            result="crash-signal6"
        else
            log "DONOR EXITED (no Signal 6) at ${elapsed}s"
            result="crash-other"
        fi
        break
    fi

    # Check joiner (node2) for sync
    state=$(docker exec lz4-pxc-node2 $MYSQL -e \
        "SHOW STATUS LIKE 'wsrep_local_state_comment'" 2>/dev/null | awk '{print $2}') || state=""
    if [ "$state" = "Synced" ]; then
        log "NODE2 SYNCED at ${elapsed}s"
        result="success"
        break
    fi

    # Check joiner for crash
    n2=$(docker inspect -f '{{.State.Status}}' lz4-pxc-node2 2>/dev/null) || n2="gone"
    if [ "$n2" = "exited" ] || [ "$n2" = "dead" ]; then
        log "JOINER EXITED at ${elapsed}s"
        result="joiner-crash"
        break
    fi

    sleep 5
    elapsed=$((elapsed + 5))
done

# Save evidence
mkdir -p "$EVIDENCE"
docker logs lz4-pxc-node1 > "$EVIDENCE/${LABEL}-node1.log" 2>&1 || true
docker logs lz4-pxc-node2 > "$EVIDENCE/${LABEL}-node2.log" 2>&1 || true

# Cleanup
$COMPOSE down -v --remove-orphans 2>/dev/null || true

echo ""
echo "================================================================"
echo "  $LABEL: $result"
echo "  Image: $IMAGE"
echo "================================================================"
