# PXB-3568: XtraBackup LZ4 Signal 6 Crash - Reproduction Lab
# https://perconadev.atlassian.net/browse/PXB-3568

set dotenv-load := false
set shell := ["bash", "-euo", "pipefail", "-c"]

project := justfile_directory()
compose := "docker compose -f " + project + "/reproduce/docker-compose.yml"

# Default: show available experiments
default:
    @echo "PXB-3568: XtraBackup LZ4 Signal 6 Crash on EL9"
    @echo ""
    @echo "  Reproduce    just reproduce     Trigger LZ4 crash during SST"
    @echo "  Fix A        just fix-a         Replace system liblz4 with 1.10.0"
    @echo "  Fix B        just fix-b         LD_PRELOAD shim for LZ4_compress_default"
    @echo "  All          just all           Run reproduce + both fixes"
    @echo ""
    @echo "  Prereqs: Docker, Docker Compose, ~2GB RAM"
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

# Run all experiments: reproduce, then both fixes
all: reproduce fix-a fix-b
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
    docker compose -f {{ project }}/reproduce/docker-compose.yml \
        -f {{ project }}/fixes/lz4-upgrade/docker-compose.override.yml \
        down -v --remove-orphans 2>/dev/null || true
    docker compose -f {{ project }}/reproduce/docker-compose.yml \
        -f {{ project }}/fixes/ld-preload-shim/docker-compose.override.yml \
        down -v --remove-orphans 2>/dev/null || true

# Remove all evidence logs
clean-evidence:
    rm -rf {{ project }}/evidence/*.log {{ project }}/evidence/*.txt
    @echo "Evidence cleaned"

# Full cleanup: containers + volumes + evidence + images
clean: down clean-evidence
    docker rmi pxc-fix-lz4:8.0.45 pxc-fix-bufsize:8.0.45 2>/dev/null || true
    @echo "Full cleanup complete"
