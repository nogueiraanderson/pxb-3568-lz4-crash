# Experiment 1: GCC 11 (system) + LTO OFF + _GLIBCXX_ASSERTIONS ON
# If crash disappears: LTO is confirmed as the cause
#
# Build: docker build -f experiments/gcc11-lto-off/Dockerfile -t pxb-exp-gcc11-nolto:8.0.45 .
# Time: ~15-20 minutes

ARG PXC_IMAGE=percona/percona-xtradb-cluster:8.0.45

FROM oraclelinux:9 AS builder

RUN dnf install -y epel-release && \
    dnf install -y 'dnf-command(config-manager)' && \
    dnf config-manager --set-enabled ol9_codeready_builder && \
    dnf install -y \
    gcc gcc-c++ binutils \
    cmake make git \
    openssl-devel libcurl-devel libaio-devel \
    ncurses-devel lz4-devel libzstd-devel \
    libgcrypt-devel libev-devel \
    procps-ng-devel vim-common zlib-devel \
    bison perl \
    && dnf clean all

# Log compiler version for evidence
RUN gcc --version | head -1 && echo "LTO: OFF" && echo "ASSERTIONS: ON (EL9 default)"

RUN git clone --depth 1 --branch 8.0 --recurse-submodules --shallow-submodules \
    https://github.com/percona/percona-xtrabackup.git /build/pxb

# Create wrapper scripts that strip -flto flags.
# CMAKE_C_FLAGS picks up -flto=auto from EL9 rpm macros via gcc specs.
# The only reliable way to disable LTO is to wrap the compiler and filter args.
RUN echo '#!/bin/bash' > /usr/local/bin/gcc-nolto && \
    echo 'args=()' >> /usr/local/bin/gcc-nolto && \
    echo 'for a in "$@"; do' >> /usr/local/bin/gcc-nolto && \
    echo '  case "$a" in -flto=*|-ffat-lto-objects) ;; *) args+=("$a") ;; esac' >> /usr/local/bin/gcc-nolto && \
    echo 'done' >> /usr/local/bin/gcc-nolto && \
    echo 'exec /usr/bin/gcc "${args[@]}"' >> /usr/local/bin/gcc-nolto && \
    sed 's|/usr/bin/gcc|/usr/bin/g++|' /usr/local/bin/gcc-nolto > /usr/local/bin/g++-nolto && \
    chmod +x /usr/local/bin/gcc-nolto /usr/local/bin/g++-nolto

# NO source patches - build the ORIGINAL code to isolate LTO as the variable
RUN cd /build/pxb && mkdir bld && cd bld && \
    cmake .. \
        -DBUILD_CONFIG=xtrabackup_release \
        -DWITH_LZ4=system \
        -DWITH_ZSTD=bundled \
        -DWITH_SSL=system \
        -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        -DDOWNLOAD_BOOST=1 \
        -DWITH_BOOST=/build/boost \
        -DCMAKE_C_COMPILER=/usr/local/bin/gcc-nolto \
        -DCMAKE_CXX_COMPILER=/usr/local/bin/g++-nolto \
        -DWITH_LTO=OFF

RUN cd /build/pxb/bld && make -j$(nproc) xtrabackup xbstream xbcloud 2>&1 | tail -5

# Verify no LTO in the binary
RUN ! nm /build/pxb/bld/runtime_output_directory/xtrabackup 2>/dev/null | grep -q lto_priv && \
    echo "VERIFIED: no .lto_priv symbols" || \
    echo "WARNING: .lto_priv symbols found (LTO may still be active)"

ARG PXC_IMAGE
FROM ${PXC_IMAGE}
USER root
COPY --from=builder /build/pxb/bld/runtime_output_directory/xtrabackup /usr/bin/pxc_extra/pxb-8.0/bin/xtrabackup
COPY --from=builder /build/pxb/bld/runtime_output_directory/xbstream /usr/bin/pxc_extra/pxb-8.0/bin/xbstream
COPY --from=builder /build/pxb/bld/runtime_output_directory/xbcloud /usr/bin/pxc_extra/pxb-8.0/bin/xbcloud
COPY --from=builder /build/pxb/bld/library_output_directory/libprotobuf-lite.so.3.19.4 /usr/lib64/libprotobuf-lite.so.3.19.4
RUN ldconfig
RUN ldd /usr/bin/pxc_extra/pxb-8.0/bin/xtrabackup | grep lz4 && \
    /usr/bin/pxc_extra/pxb-8.0/bin/xtrabackup --version 2>&1 | head -3
USER mysql
