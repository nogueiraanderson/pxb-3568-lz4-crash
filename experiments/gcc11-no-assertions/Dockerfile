# Experiment 2: GCC 11 (system) + LTO ON + _GLIBCXX_ASSERTIONS OFF
# If crash disappears: confirms the assertion is the direct crash mechanism
# If crash persists: there is a real bug (not just a false-positive assertion)
#
# Build: docker build -f experiments/gcc11-no-assertions/Dockerfile -t pxb-exp-gcc11-noassert:8.0.45 .
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

RUN gcc --version | head -1 && echo "LTO: ON" && echo "ASSERTIONS: OFF (explicitly disabled)"

RUN git clone --depth 1 --branch 8.0 --recurse-submodules --shallow-submodules \
    https://github.com/percona/percona-xtrabackup.git /build/pxb

# NO source patches - build ORIGINAL code, only disable assertions
RUN cd /build/pxb && mkdir bld && cd bld && \
    cmake .. \
        -DBUILD_CONFIG=xtrabackup_release \
        -DWITH_LZ4=system \
        -DWITH_ZSTD=bundled \
        -DWITH_SSL=system \
        -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        -DDOWNLOAD_BOOST=1 \
        -DWITH_BOOST=/build/boost \
        -DCMAKE_C_COMPILER=/usr/bin/gcc \
        -DCMAKE_CXX_COMPILER=/usr/bin/g++ \
        -DCMAKE_CXX_FLAGS="-U_GLIBCXX_ASSERTIONS"

RUN cd /build/pxb/bld && make -j$(nproc) xtrabackup xbstream xbcloud 2>&1 | tail -5

# Verify assertions are disabled in the binary
RUN ! strings /build/pxb/bld/runtime_output_directory/xtrabackup | grep -q "__glibcxx_requires_subscript" && \
    echo "VERIFIED: no assertion strings found" || \
    echo "INFO: assertion strings present (may be from headers)"

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
