# Fix A: Replace system liblz4 with 1.10.0
#
# In LZ4 >= 1.10.0, LZ4_compressBound returns a correctly sized value
# that avoids the boundary condition (LZ4 issue #1374). This works
# around the xtrabackup buffer sizing bug without patching xtrabackup.
ARG PXC_IMAGE=percona/percona-xtradb-cluster:8.0.45
FROM ${PXC_IMAGE}

USER root

RUN microdnf install -y gcc make tar gzip && \
    microdnf clean all

RUN cd /tmp && \
    curl -fsSL https://github.com/lz4/lz4/archive/refs/tags/v1.10.0.tar.gz -o lz4-1.10.0.tar.gz && \
    tar xzf lz4-1.10.0.tar.gz && \
    cd lz4-1.10.0 && \
    make -j$(nproc) && \
    cp lib/liblz4.so.1.10.0 /usr/lib64/liblz4.so.1.10.0 && \
    ln -sf liblz4.so.1.10.0 /usr/lib64/liblz4.so.1 && \
    ln -sf liblz4.so.1.10.0 /usr/lib64/liblz4.so && \
    ldconfig && \
    rm -rf /tmp/lz4-*

RUN ldd /usr/bin/pxc_extra/pxb-8.0/bin/xtrabackup | grep lz4 && \
    ls -la /usr/lib64/liblz4.so*

USER mysql
