# Isolated BTX GPU solo-miner — COMPILES btxchain/btx from source.
#
# Upstream bumped to 0.30.2 (2026-06-01) but has NOT yet cut a v0.30.2 tag or a
# GPG-signed precompiled release (no GitHub Actions builds them). So to run
# 0.30.2 now we compile it ourselves, WITH the CUDA MatMul backend, from a
# pinned upstream commit. When the signed v0.30.2 archives land, switch back to
# the precompiled path: set BTX_INSTALL_MODE=release + RELEASE_TAG=v0.30.2 in
# docker-compose.yml (the entrypoint keeps that path intact).
#
# Trust boundary note: the old design ran ONLY the GPG-signed release. A source
# build trades that signature for a pinned, immutable commit SHA. Acceptable
# here ONLY because everything runs sandboxed in this container with no funds —
# same caveat the entrypoint already documents.

# ---------- Stage 1: compile btxd + btx-cli (+ matmul tools) with CUDA ----------
# Compiling needs nvcc, so this stage uses the CUDA *devel* image (the runtime
# stage below uses -runtime). Keep the CUDA major line matching the runtime base
# and the host driver (README requires R580+ for the 5090 / CUDA 13).
ARG CUDA_DEVEL_IMAGE=nvidia/cuda:13.0.0-devel-ubuntu24.04
FROM ${CUDA_DEVEL_IMAGE} AS builder
ENV DEBIAN_FRONTEND=noninteractive

# Exact upstream commit to compile. 0.30.2 = main HEAD as of 2026-06-01T21:37Z
# (CLIENT_VERSION_BUILD=2); no v0.30.2 tag/signed release exists yet. An
# immutable SHA means every rebuild on every box produces a byte-identical tree.
ARG BTX_SOURCE_REF=2da3b1754d35ae157229f878a858f169a8061d28
# sm_120 = NVIDIA Blackwell (RTX 5090). Other GPUs: Ada=89, Hopper=90, Ampere=80/86.
ARG BTX_CUDA_ARCHITECTURES=120

# Bitcoin-core (CMake) build deps + git to fetch the pinned commit.
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential cmake pkg-config python3 git ca-certificates \
      libevent-dev libsqlite3-dev libboost-dev \
 && rm -rf /var/lib/apt/lists/*

# Fetch ONLY the pinned commit (GitHub serves any commit reachable from a ref),
# then check it out detached. Reproducible even as main advances past it.
WORKDIR /opt/btx-src
RUN git init -q \
 && git remote add origin https://github.com/btxchain/btx.git \
 && git fetch --depth 1 origin "${BTX_SOURCE_REF}" \
 && git checkout -q FETCH_HEAD

# Configure with the CUDA MatMul backend (see upstream doc/build-unix.md):
#   - node + cli + wallet(sqlite) only; no GUI/tests/bench/tx/util/bdb/zmq.
#   - CUDA runtime STATICALLY linked, matching the official cuda13 archives, so
#     the runtime image needs no CUDA libs — only the host NVIDIA driver (which
#     nvidia-container-toolkit injects at run time).
RUN cmake -B build \
      -DCMAKE_BUILD_TYPE=Release \
      -DBTX_ENABLE_CUDA_EXPERIMENTAL=ON \
      -DBTX_CUDA_ARCHITECTURES="${BTX_CUDA_ARCHITECTURES}" \
      -DBTX_CUDA_RUNTIME_LIBRARY=Static \
      -DCUDAToolkit_ROOT=/usr/local/cuda \
      -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc \
      -DBUILD_DAEMON=ON -DBUILD_CLI=ON -DENABLE_WALLET=ON -DWITH_SQLITE=ON \
      -DBUILD_GUI=OFF -DBUILD_TESTS=OFF -DBUILD_BENCH=OFF -DBUILD_TX=OFF \
      -DBUILD_UTIL=OFF -DBUILD_WALLET_TOOL=OFF -DBUILD_UTIL_CHAINSTATE=OFF \
      -DWITH_BDB=OFF -DWITH_ZMQ=OFF -DWITH_USDT=OFF -DINSTALL_MAN=OFF \
      -DWITH_CCACHE=OFF \
 && cmake --build build --parallel "$(nproc)" \
 && strip --strip-unneeded build/bin/btxd build/bin/btx-cli || true

# ---------- Stage 2: lean CUDA runtime ----------
ARG CUDA_RUNTIME_IMAGE=nvidia/cuda:13.0.0-runtime-ubuntu24.04
FROM ${CUDA_RUNTIME_IMAGE}
ENV DEBIAN_FRONTEND=noninteractive

# Runtime shared libs the compiled binaries link (libevent / sqlite / boost /
# OpenMP) plus the entrypoint's own tools (curl, jq, python3 for snapshot +
# wallet ops; gnupg is only used by the release-mode fallback). The boost
# *1.83.0 names track Ubuntu 24.04 "Noble" — bump them if CUDA_RUNTIME_IMAGE's
# Ubuntu release changes.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl jq python3 gnupg \
      libevent-2.1-7t64 libsqlite3-0 libgomp1 \
      libboost-system1.83.0 libboost-filesystem1.83.0 libboost-program-options1.83.0 \
 && rm -rf /var/lib/apt/lists/*

# Compiled 0.30.2 binaries (btxd, btx-cli, btx-matmul-*) + the contrib/ scripts
# the entrypoint drives at run time (mining loop; faststart for release mode).
COPY --from=builder /opt/btx-src/build/bin/ /opt/btx/bin/
COPY --from=builder /opt/btx-src/contrib/   /opt/btx-src/contrib/
ENV PATH=/opt/btx/bin:${PATH}

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

VOLUME ["/data"]
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
