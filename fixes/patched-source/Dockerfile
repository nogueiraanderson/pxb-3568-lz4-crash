# Fix C: Build XtraBackup from source with ds_compress_lz4.cc patch applied
#
# Multi-stage build:
#   Stage 1: Clone percona-xtrabackup 8.0, apply patch, build xtrabackup/xbstream
#   Stage 2: Copy patched binaries into PXC 8.0.45 image
#
# Build time: ~15-20 minutes (builds only xtrabackup target, not full mysqld)
# Disk: ~4GB for build stage (discarded after multi-stage copy)
#
# Build context MUST be the project root (for patch file access):
#   docker build -f fixes/patched-source/Dockerfile -t pxc-fix-patched:8.0.45 .

# ── Stage 1: Builder ──────────────────────────────────────────────
FROM oraclelinux:9 AS builder

RUN dnf install -y \
    cmake gcc gcc-c++ make git \
    openssl-devel libcurl-devel libaio-devel \
    ncurses-devel lz4-devel libzstd-devel \
    libgcrypt-devel libev-devel \
    bison perl \
    && dnf clean all

# Shallow clone: single commit of 8.0 branch (~300MB vs multi-GB full history)
RUN git clone --depth 1 --branch 8.0 \
    https://github.com/percona/percona-xtrabackup.git /build/pxb

# Apply the patch (build context is project root)
COPY patch/ds_compress_lz4.patch /build/ds_compress_lz4.patch
RUN cd /build/pxb && git apply /build/ds_compress_lz4.patch

# Configure: system LZ4 (matches PXC Docker image dynamic linking)
RUN cd /build/pxb && mkdir bld && cd bld && \
    cmake .. \
        -DBUILD_CONFIG=xtrabackup_release \
        -DWITH_LZ4=system \
        -DWITH_ZSTD=bundled \
        -DWITH_SSL=system \
        -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        -DDOWNLOAD_BOOST=1 \
        -DWITH_BOOST=/build/boost

# Build only xtrabackup targets (skip mysqld, router, shell)
RUN cd /build/pxb/bld && make -j$(nproc) xtrabackup xbstream xbcloud

# ── Stage 2: Runtime ──────────────────────────────────────────────
ARG PXC_IMAGE=percona/percona-xtradb-cluster:8.0.45
FROM ${PXC_IMAGE}

USER root

# Replace xtrabackup binaries with patched versions
COPY --from=builder /build/pxb/bld/storage/innobase/xtrabackup/src/xtrabackup /usr/bin/xtrabackup
COPY --from=builder /build/pxb/bld/storage/innobase/xtrabackup/src/xbstream /usr/bin/xbstream
COPY --from=builder /build/pxb/bld/storage/innobase/xtrabackup/src/xbcloud /usr/bin/xbcloud

# Verify binary links system liblz4 and runs
RUN ldd /usr/bin/xtrabackup | grep lz4 && \
    /usr/bin/xtrabackup --version 2>&1 | head -1

USER mysql
