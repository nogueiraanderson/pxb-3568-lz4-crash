# Fix B: Patch xtrabackup via LD_PRELOAD shim
#
# Since we cannot easily recompile xtrabackup in a container, this
# uses an LD_PRELOAD shim that wraps LZ4_compress_default to handle
# the undersized output buffer from the comp_buf_size bug.
ARG PXC_IMAGE=percona/percona-xtradb-cluster:8.0.45
FROM ${PXC_IMAGE}

USER root

RUN microdnf install -y gcc && microdnf clean all

COPY lz4_fix.c /tmp/lz4_fix.c
RUN gcc -shared -fPIC -o /usr/lib64/lz4_fix.so /tmp/lz4_fix.c -ldl && \
    rm /tmp/lz4_fix.c

# Set LD_PRELOAD globally so xtrabackup picks it up during SST
RUN echo '/usr/lib64/lz4_fix.so' >> /etc/ld.so.preload

USER mysql
