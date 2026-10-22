# llama-server from the PrismML llama.cpp fork (PQ2_0 / PTQ1_0 kernels), prebuilt for
# Linux x64 + CUDA 13.3 (fat binary: sm_75/80/86/89/90/120a/121a SASS, no JIT on start).
#
# Build context is the repository root (see compose.yaml). The build needs no network:
# `deploy/linux-cuda/fetch.sh binaries` downloads the release tarball and the libgomp1
# .deb into deploy/linux-cuda/build/ (sha256-checked; works through a proxy), and this
# file checks both digests again. That keeps the build working on hosts whose docker
# daemon / BuildKit cannot reach the internet.
#
# Needs a driver that supports CUDA 13.3 (nvidia-smi "CUDA Version" >= 13.3).

FROM nvidia/cuda:13.3.1-runtime-ubuntu24.04

ARG LLAMA_RELEASE=prism-b10787-73bfe6c
ARG LLAMA_ASSET_SHA256=e2d492f50d70f3e01b4b3ae68f670ae6825870d97206fb1bcb5b4376640c0e0c
# The binaries need libgomp1, which the CUDA runtime image lacks. The .deb comes from
# fetch.sh as well (no network during the build), pinned to the version of the image's
# own gcc-14 runtime so nothing else in the base changes.
ARG LIBGOMP1_DEB=libgomp1_14.2.0-4ubuntu2~24.04.1_amd64.deb
ARG LIBGOMP1_SHA256=e8a95ec58125b4933597f30ff56c2ae10edf90f287262e366d4b6edea3019144

COPY deploy/linux-cuda/build/${LIBGOMP1_DEB} /tmp/libgomp1.deb
RUN set -eux; \
    echo "${LIBGOMP1_SHA256}  /tmp/libgomp1.deb" | sha256sum -c -; \
    dpkg -i /tmp/libgomp1.deb; \
    rm /tmp/libgomp1.deb

COPY deploy/linux-cuda/build/llama-${LLAMA_RELEASE}-bin-linux-cuda-13.3-x64.tar.gz /tmp/llama.tar.gz
RUN set -eux; \
    echo "${LLAMA_ASSET_SHA256}  /tmp/llama.tar.gz" | sha256sum -c -; \
    mkdir -p /opt/llama; \
    tar -xzf /tmp/llama.tar.gz -C /opt/llama --strip-components=1; \
    rm /tmp/llama.tar.gz; \
    printf '%s cuda-13.3\n' "${LLAMA_RELEASE}" > /opt/llama/.llama_release; \
    ! LD_LIBRARY_PATH=/opt/llama ldd /opt/llama/llama-server /opt/llama/libggml-cuda.so | grep 'not found' | grep -v libcuda.so

# The demo's own launcher decides the flags (sampling, --jinja, mmproj, KV4, alias ...),
# so the container behaves like ./scripts/start_llama_server.sh on a workstation.
COPY scripts/common.sh scripts/start_llama_server.sh scripts/webui-config.json /opt/bonsai/scripts/
COPY deploy/linux-cuda/entrypoint.sh /opt/bonsai/entrypoint.sh
RUN chmod 0755 /opt/bonsai/entrypoint.sh /opt/bonsai/scripts/start_llama_server.sh

ENV BONSAI_LLAMA_BIN=/opt/llama \
    LD_LIBRARY_PATH=/opt/llama \
    BONSAI_HOST=0.0.0.0 \
    PORT=8081

EXPOSE 8081
WORKDIR /opt/bonsai
ENTRYPOINT ["/opt/bonsai/entrypoint.sh"]
