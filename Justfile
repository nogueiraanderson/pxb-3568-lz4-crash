# PXB-3568: XtraBackup LZ4 Signal 6 Crash - Reproduction Lab
# https://perconadev.atlassian.net/browse/PXB-3568

set dotenv-load := false
set shell := ["bash", "-euo", "pipefail", "-c"]

project := justfile_directory()
compose := "docker compose -f " + project + "/reproduce/docker-compose.yml"
compose-amd64 := compose + " -f " + project + "/reproduce/docker-compose.amd64.yml"

# Default: show available experiments
default:
    @echo "PXB-3568: XtraBackup LZ4 Signal 6 Crash on EL9"
    @echo ""
    @echo "  Reproduce    just reproduce     Trigger LZ4 crash during SST"
    @echo "  Fix A        just fix-a         Replace system liblz4 with 1.10.0"
    @echo "  Fix B        just fix-b         LD_PRELOAD shim for LZ4_compress_default"
    @echo "  Fix C        just fix-c         Patched xtrabackup from source (before/after)"
    @echo "  All          just all           Run reproduce + all fixes"
    @echo ""
    @echo "  Prereqs: Docker, Docker Compose, just, ~2GB RAM"
    @echo "  Image:   percona/percona-xtradb-cluster:8.0.45"
    @echo ""
    @just --list

# ─── Experiments ──────────────────────────────────────────────────

# Reproduce the LZ4 crash (3 SST attempts by default)
reproduce *ARGS:
    chmod +x {{ project }}/reproduce/test-reproduce.sh
    {{ project }}/reproduce/test-reproduce.sh {{ ARGS }}

# Fix A: Test with LZ4 1.10.0 replacing system library
fix-a *ARGS:
    chmod +x {{ project }}/fixes/lz4-upgrade/test-fix-a.sh
    {{ project }}/fixes/lz4-upgrade/test-fix-a.sh {{ ARGS }}

# Fix B: Test with LD_PRELOAD buffer size shim
fix-b *ARGS:
    chmod +x {{ project }}/fixes/ld-preload-shim/test-fix-b.sh
    {{ project }}/fixes/ld-preload-shim/test-fix-b.sh {{ ARGS }}

# Fix C: Before/after with patched xtrabackup built from source (~20min build)
fix-c *ARGS:
    chmod +x {{ project }}/fixes/patched-source/test-fix-c.sh
    {{ project }}/fixes/patched-source/test-fix-c.sh {{ ARGS }}

# Run all experiments: reproduce, workarounds, then patch validation
all: reproduce fix-a fix-b fix-c
    @echo ""
    @echo "All experiments complete. Check evidence/ for logs."

# ─── Build ────────────────────────────────────────────────────────

# Build Fix A image (LZ4 1.10.0)
build-fix-a:
    docker compose -f {{ project }}/reproduce/docker-compose.yml \
        -f {{ project }}/fixes/lz4-upgrade/docker-compose.override.yml \
        build --no-cache

# Build Fix B image (LD_PRELOAD shim)
build-fix-b:
    docker compose -f {{ project }}/reproduce/docker-compose.yml \
        -f {{ project }}/fixes/ld-preload-shim/docker-compose.override.yml \
        build --no-cache

# Build Fix C image (patched xtrabackup from source, ~15-20 min)
build-patched:
    docker build -f {{ project }}/fixes/patched-source/Dockerfile \
        -t pxc-fix-patched:8.0.45 {{ project }}

# ─── Isolation Experiments ────────────────────────────────────────

# Build and test an isolation experiment image
# Usage: just experiment <name> where name is a subdirectory of experiments/
experiment name:
    docker build -f {{ project }}/experiments/{{ name }}/Dockerfile \
        -t pxb-exp-{{ name }}:8.0.45 {{ project }}
    chmod +x {{ project }}/experiments/test-experiment.sh
    {{ project }}/experiments/test-experiment.sh pxb-exp-{{ name }}:8.0.45 "{{ name }}"

# Build all 4 experiment images (~20 min each)
build-experiments:
    just experiment gcc11-lto-off
    just experiment gcc11-no-assertions
    just experiment gcc12-lto-on
    just experiment patched-data-fix

# ─── x86_64 (amd64) Testing ──────────────────────────────────────

# Reproduce on x86_64 (requires QEMU binfmt or x86_64 Docker host)
reproduce-amd64 *ARGS:
    @echo "=== x86_64 reproduction (QEMU emulation) ==="
    @docker run --rm --platform linux/amd64 alpine uname -m | grep -q x86_64 || \
        (echo "ERROR: amd64 emulation not available. Run: docker run --rm --privileged tonistiigi/binfmt --install amd64" && exit 1)
    chmod +x {{ project }}/reproduce/test-reproduce.sh
    cd {{ project }}/reproduce && \
        COMPOSE_FILE=docker-compose.yml:docker-compose.amd64.yml \
        {{ project }}/reproduce/test-reproduce.sh {{ ARGS }}

# Quick single-node LZ4 backup test on x86_64 (faster than full SST)
test-amd64:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=== x86_64 single-node LZ4 backup test ==="
    docker run --rm --platform linux/amd64 alpine uname -m | grep -q x86_64 || \
        { echo "ERROR: amd64 emulation not available"; exit 1; }
    CONTAINER="pxb-amd64-test"
    XB="/usr/bin/pxc_extra/pxb-8.0/bin/xtrabackup"
    MYSQL="mysql -uroot -proot -N"
    cleanup() { docker rm -f "$CONTAINER" 2>/dev/null || true; }
    trap cleanup EXIT
    cleanup
    echo "[1/5] Starting PXC 8.0.45 (amd64)..."
    docker run -d --name "$CONTAINER" --platform linux/amd64 --privileged \
        -e MYSQL_ROOT_PASSWORD=root \
        -e CLUSTER_NAME=amd64-test \
        -e "CLUSTER_JOIN=" \
        percona/percona-xtradb-cluster:8.0.45 mysqld \
        --pxc_encrypt_cluster_traffic=OFF \
        --innodb_buffer_pool_size=256M \
        --innodb_log_file_size=128M \
        --innodb_flush_log_at_trx_commit=0
    echo "[2/5] Waiting for MySQL ready (up to 180s, slower under QEMU)..."
    for i in $(seq 1 60); do
        if docker exec "$CONTAINER" $MYSQL -e "SELECT 1" &>/dev/null; then
            ready=$(docker exec "$CONTAINER" $MYSQL -e "SHOW STATUS LIKE 'wsrep_ready'" 2>/dev/null | awk '{print $2}') || ready=""
            if [ "$ready" = "ON" ]; then echo "  MySQL ready"; break; fi
        fi
        sleep 3
    done
    echo "  Architecture: $(docker exec "$CONTAINER" uname -m)"
    echo "  XtraBackup: $(docker exec "$CONTAINER" $XB --version 2>&1 | head -1)"
    echo "[3/5] Loading test data (~30MB)..."
    docker exec "$CONTAINER" $MYSQL -e "CREATE DATABASE pxb3568" 2>/dev/null
    docker exec "$CONTAINER" $MYSQL pxb3568 -e \
        "CREATE TABLE t (id INT AUTO_INCREMENT PRIMARY KEY, data BLOB) ENGINE=InnoDB" 2>/dev/null
    for batch in $(seq 1 10); do
        docker exec "$CONTAINER" $MYSQL pxb3568 -e "
            INSERT INTO t (data)
            SELECT UNHEX(REPEAT(SHA2(RAND(),256), 2000))
            FROM (SELECT 1 a UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5
                  UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9 UNION SELECT 10) t1
            CROSS JOIN (SELECT 1 b UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5) t2;
        " 2>/dev/null
    done
    rows=$(docker exec "$CONTAINER" $MYSQL -e "SELECT COUNT(*) FROM pxb3568.t" 2>/dev/null | tr -d ' ')
    echo "  Loaded $rows rows"
    echo "[4/5] Starting concurrent writes + LZ4 backup..."
    for i in $(seq 1 30); do
        docker exec "$CONTAINER" $MYSQL pxb3568 -e "
            INSERT INTO t (data)
            SELECT UNHEX(REPEAT(SHA2(RAND(),256), 2000))
            FROM (SELECT 1 a UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5
                  UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9 UNION SELECT 10) t1
            CROSS JOIN (SELECT 1 b UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5) t2;
        " 2>/dev/null &
    done
    output=$(docker exec "$CONTAINER" bash -c "
        rm -rf /tmp/backup-lz4 && mkdir -p /tmp/backup-lz4
        $XB --backup --user=root --password=root \
            --compress=lz4 --compress-chunk-size=65534 \
            --target-dir=/tmp/backup-lz4 --no-server-version-check 2>&1
        echo EXIT_STATUS=\$?
    " 2>&1)
    wait 2>/dev/null || true
    echo "[5/5] Result:"
    if echo "$output" | grep -q "completed OK"; then
        echo "  SUCCESS (completed OK)"
        result="SUCCESS"
    elif echo "$output" | grep -qE "terribly wrong|Fatal signal"; then
        echo "  CRASH (Signal 6)"
        result="CRASH"
    else
        exit_code=$(echo "$output" | grep "EXIT_STATUS=" | tail -1 | cut -d= -f2)
        echo "  EXIT CODE: $exit_code"
        result="EXIT-$exit_code"
    fi
    mkdir -p {{ project }}/evidence/amd64
    echo "$output" > {{ project }}/evidence/amd64/test-amd64.log
    echo ""
    echo "================================================================"
    echo "  Platform:   x86_64 (QEMU emulation on aarch64)"
    echo "  LZ4 backup: $result"
    echo "  Evidence:   evidence/amd64/test-amd64.log"
    echo "================================================================"

# Build and test an isolation experiment on amd64 (QEMU emulation)
experiment-amd64 name:
    docker build --platform linux/amd64 \
        -f {{ project }}/experiments/{{ name }}/Dockerfile \
        -t pxb-exp-{{ name }}-amd64:8.0.45 {{ project }}
    chmod +x {{ project }}/experiments/test-experiment.sh
    {{ project }}/experiments/test-experiment.sh pxb-exp-{{ name }}-amd64:8.0.45 "{{ name }}-amd64"

# Check if amd64 emulation is available
check-amd64:
    @docker run --rm --platform linux/amd64 alpine uname -m 2>/dev/null && \
        echo "amd64 emulation: OK" || \
        echo "amd64 emulation: NOT AVAILABLE (run: docker run --rm --privileged tonistiigi/binfmt --install amd64)"

# ─── Inspection ───────────────────────────────────────────────────

# Show LZ4 version and linking in the stock PXC image
check-lz4:
    @echo "=== System LZ4 ==="
    docker run --rm percona/percona-xtradb-cluster:8.0.45 \
        bash -c "rpm -q lz4-libs; ldd /usr/bin/xtrabackup | grep lz4"

# Show xtrabackup version in the stock PXC image
check-xtrabackup:
    docker run --rm percona/percona-xtradb-cluster:8.0.45 \
        xtrabackup --version 2>&1

# ─── Cleanup ──────────────────────────────────────────────────────

# Stop and remove all containers + volumes
down:
    {{ compose }} down -v --remove-orphans 2>/dev/null || true
    {{ compose-amd64 }} down -v --remove-orphans 2>/dev/null || true
    docker rm -f pxb-amd64-test 2>/dev/null || true
    docker compose -f {{ project }}/reproduce/docker-compose.yml \
        -f {{ project }}/fixes/lz4-upgrade/docker-compose.override.yml \
        down -v --remove-orphans 2>/dev/null || true
    docker compose -f {{ project }}/reproduce/docker-compose.yml \
        -f {{ project }}/fixes/ld-preload-shim/docker-compose.override.yml \
        down -v --remove-orphans 2>/dev/null || true
    docker compose -f {{ project }}/reproduce/docker-compose.yml \
        -f {{ project }}/fixes/patched-source/docker-compose.override.yml \
        down -v --remove-orphans 2>/dev/null || true

# Remove all evidence
clean-evidence:
    rm -rf {{ project }}/evidence/*.log {{ project }}/evidence/*.txt {{ project }}/evidence/patched-source/
    @echo "Evidence cleaned"

# Full cleanup: containers + volumes + evidence + images
clean: down clean-evidence
    docker rmi pxc-fix-lz4:8.0.45 pxc-fix-bufsize:8.0.45 pxc-fix-patched:8.0.45 2>/dev/null || true
    @echo "Full cleanup complete"
