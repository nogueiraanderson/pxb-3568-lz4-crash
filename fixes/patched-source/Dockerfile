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

ARG PXC_IMAGE=percona/percona-xtradb-cluster:8.0.45

# ── Stage 1: Builder ──────────────────────────────────────────────
FROM oraclelinux:9 AS builder

RUN dnf install -y epel-release && \
    dnf install -y 'dnf-command(config-manager)' && \
    dnf config-manager --set-enabled ol9_codeready_builder && \
    dnf install -y \
    gcc-toolset-12-gcc gcc-toolset-12-gcc-c++ gcc-toolset-12-binutils \
    gcc-toolset-12-annobin-annocheck gcc-toolset-12-annobin-plugin-gcc \
    cmake make git \
    openssl-devel libcurl-devel libaio-devel \
    ncurses-devel lz4-devel libzstd-devel \
    libgcrypt-devel libev-devel \
    procps-ng-devel vim-common zlib-devel \
    bison perl \
    && dnf clean all

# Enable gcc-toolset-12 for all subsequent RUN commands
ENV PATH="/opt/rh/gcc-toolset-12/root/usr/bin:${PATH}" \
    LD_LIBRARY_PATH="/opt/rh/gcc-toolset-12/root/usr/lib64"

# Shallow clone: single commit of 8.0 branch (~300MB vs multi-GB full history)
RUN git clone --depth 1 --branch 8.0 --recurse-submodules --shallow-submodules \
    https://github.com/percona/percona-xtrabackup.git /build/pxb

# Apply the 4 fixes to ds_compress_lz4.cc (see patch/PATCH-NOTES.md)
COPY patch/apply-fix.sh /build/apply-fix.sh
RUN chmod +x /build/apply-fix.sh && \
    /build/apply-fix.sh /build/pxb/storage/innobase/xtrabackup/src/ds_compress_lz4.cc

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
ARG PXC_IMAGE
FROM ${PXC_IMAGE}

USER root

# Replace xtrabackup binaries with patched versions
# PXC 8.0.45 stores xtrabackup at /usr/bin/pxc_extra/pxb-8.0/bin/
COPY --from=builder /build/pxb/bld/runtime_output_directory/xtrabackup /usr/bin/pxc_extra/pxb-8.0/bin/xtrabackup
COPY --from=builder /build/pxb/bld/runtime_output_directory/xbstream /usr/bin/pxc_extra/pxb-8.0/bin/xbstream
COPY --from=builder /build/pxb/bld/runtime_output_directory/xbcloud /usr/bin/pxc_extra/pxb-8.0/bin/xbcloud

# Copy bundled libraries that may differ from the PXC image
COPY --from=builder /build/pxb/bld/library_output_directory/libprotobuf-lite.so.3.19.4 /usr/lib64/libprotobuf-lite.so.3.19.4
RUN ldconfig

# Verify binary links system liblz4 and runs
RUN ldd /usr/bin/pxc_extra/pxb-8.0/bin/xtrabackup | grep lz4 && \
    /usr/bin/pxc_extra/pxb-8.0/bin/xtrabackup --version 2>&1 | head -3

USER mysql
