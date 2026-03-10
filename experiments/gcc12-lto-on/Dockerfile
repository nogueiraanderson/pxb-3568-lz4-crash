# Experiment 3: GCC 12 (toolset) + LTO ON + _GLIBCXX_ASSERTIONS ON
# If crash disappears: confirms GCC 11 specific LTO bug
# If crash persists: the bug is not GCC-version-specific
#
# Build: docker build -f experiments/gcc12-lto-on/Dockerfile -t pxb-exp-gcc12-lto:8.0.45 .
# Time: ~15-20 minutes

ARG PXC_IMAGE=percona/percona-xtradb-cluster:8.0.45

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

ENV PATH="/opt/rh/gcc-toolset-12/root/usr/bin:${PATH}" \
    LD_LIBRARY_PATH="/opt/rh/gcc-toolset-12/root/usr/lib64"

RUN gcc --version | head -1 && echo "LTO: ON" && echo "ASSERTIONS: ON (EL9 default)"

RUN git clone --depth 1 --branch 8.0 --recurse-submodules --shallow-submodules \
    https://github.com/percona/percona-xtrabackup.git /build/pxb

# NO source patches - build ORIGINAL code with GCC 12 + LTO
RUN cd /build/pxb && mkdir bld && cd bld && \
    cmake .. \
        -DBUILD_CONFIG=xtrabackup_release \
        -DWITH_LZ4=system \
        -DWITH_ZSTD=bundled \
        -DWITH_SSL=system \
        -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        -DDOWNLOAD_BOOST=1 \
        -DWITH_BOOST=/build/boost

RUN cd /build/pxb/bld && make -j$(nproc) xtrabackup xbstream xbcloud 2>&1 | tail -5

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
