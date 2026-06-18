# Isolated BTX GPU solo-miner — COMPILES btxchain/btx from source.
#
# Pinned to the v0.32.12 tag commit, compiled WITH the CUDA MatMul backend.
# Upstream ships GPG-signed cuda13 prebuilts for tagged releases, but we compile
# by choice: it guarantees native sm_120 codegen for the RTX 5090 (the prebuilt's
# embedded archs are unverified) and yields a byte-reproducible build from an
# immutable SHA. To run the signed prebuilt instead, set BTX_INSTALL_MODE=release
# + RELEASE_TAG=v0.32.12 in docker-compose.yml (the entrypoint keeps that path).
#
# 0.32.12 is a CONSENSUS-only follow-up to 0.32.11 (NO src/cuda or src/metal changes):
# it MOVES the shielded-unshield velocity-cap EXIT from height 132,000 to 135,000 and
# ships v9 assumeutxo snapshots at heights 132,142-132,209 (the live chain is already
# PAST 132,000), so upgrade before 135,000. It inherits 0.32.11's HARDENED MatMul v3
# parent-MTP seed handling across CPU/Metal/CUDA (the v3 GPU-scan stall fix hit on
# 0.32.10). (0.32.10 added the MatMul SEED-DERIVATION
# v3 CONSENSUS upgrade at HEIGHT 130,500 — the v2 seed binds more chain data; all
# nodes/miners/pools/services had to upgrade before 130,500.) The v3 change lives in
# pow.cpp + chainparams/validation; src/cuda/ is otherwise UNTOUCHED, so the stock
# build compiles the official v3 logic verbatim and stays consensus-correct
# (APPLY_LOCAL_PATCHES=0; our PR #58 kernels remain upstreamed). (0.32.9 = the
# empty-block subsidy rule @130,000 + 25-tx template cap + reorg-parking; 0.32.8
# upstreamed our six PR #58 CUDA patches; 0.32.7 = validation/chainparams/miner/
# mempool + assumeutxo; 0.32.6 shielded recovery-exit + block-128,000 cleanup;
# 0.32.5 Metal-only; 0.32.4 operator-safety; 0.32.3 on-GPU pre-hash scanner; 0.32.2
# block-125,000 shielded-sunset + nonce-seed-v2 fork, 2026-06-08.)
#
# Trust boundary note: the release signing key is integrity-only (self-published
# with the release, nobody independent vouches — see entrypoint.sh), so a pinned
# commit SHA is comparable trust. Acceptable here ONLY because everything runs
# sandboxed in this container with no funds — same caveat the entrypoint documents.

# Base images. An ARG consumed by a FROM must be declared in the global scope
# BEFORE the first FROM, so BOTH live here (not next to their own stage).
ARG CUDA_DEVEL_IMAGE=nvidia/cuda:13.0.0-devel-ubuntu24.04
ARG CUDA_RUNTIME_IMAGE=nvidia/cuda:13.0.0-runtime-ubuntu24.04

# ---------- Stage 1: compile btxd + btx-cli (+ matmul tools) with CUDA ----------
# Compiling needs nvcc, so this stage uses the CUDA *devel* image (the runtime
# stage below uses -runtime). Keep the CUDA major line matching the runtime base
# and the host driver (README requires R580+ for the 5090 / CUDA 13).
FROM ${CUDA_DEVEL_IMAGE} AS builder
ENV DEBIAN_FRONTEND=noninteractive

# Exact upstream commit to compile. f3c9eb77 = the v0.32.12 release tag commit. An
# immutable SHA means every rebuild on every box produces a byte-identical tree.
ARG BTX_SOURCE_REF=f3c9eb77fa547a48862bc9bcec5f0d6acf4f0bb8
# sm_120 = NVIDIA Blackwell (RTX 5090). Other GPUs: Ada=89, Hopper=90, Ampere=80/86.
ARG BTX_CUDA_ARCHITECTURES=120

# Bitcoin-core (CMake) build deps + git to fetch the pinned commit. ccache caches
# compiler output (incl. nvcc, via CMAKE_CUDA_COMPILER_LAUNCHER below) so a node
# SHA bump only recompiles the changed translation units — the big win on the slow
# CUDA TUs. The cache persists across builds via a BuildKit cache mount on the
# build step. ccache caches the EXACT compiler output, so the built tree is
# bit-identical to a no-ccache build (the pinned-SHA reproducibility guarantee holds).
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential ccache cmake pkg-config python3 git ca-certificates \
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
#   - node + cli + wallet(sqlite). BUILD_UTIL=ON only because the btx-matmul-*
#     diagnostic + solve-bench tools are gated behind it in src/CMakeLists.txt.
#     No GUI/tests/bench/tx/bdb/zmq.
#   - CUDA runtime STATICALLY linked, matching the official cuda13 archives, so
#     the runtime image needs no CUDA libs — only the host NVIDIA driver (which
#     nvidia-container-toolkit injects at run time).
# Persist ccache across builds via a BuildKit cache mount (requires BuildKit, the
# default for `docker compose build` / `docker build` on modern Docker). WITH_CCACHE
# wires the C/C++ launchers; CMAKE_CUDA_COMPILER_LAUNCHER routes nvcc through ccache
# too (the slow CUDA TUs are where the rebuild win is). A clean build is a full
# miss (no slower than before); a node SHA bump reuses the unchanged TUs.
ENV CCACHE_DIR=/ccache CCACHE_MAXSIZE=5G
RUN --mount=type=cache,target=/ccache \
    cmake -B build \
      -DCMAKE_BUILD_TYPE=Release \
      -DBTX_ENABLE_CUDA_EXPERIMENTAL=ON \
      -DBTX_CUDA_ARCHITECTURES="${BTX_CUDA_ARCHITECTURES}" \
      -DBTX_CUDA_RUNTIME_LIBRARY=Static \
      -DCUDAToolkit_ROOT=/usr/local/cuda \
      -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc \
      -DBUILD_DAEMON=ON -DBUILD_CLI=ON -DENABLE_WALLET=ON -DWITH_SQLITE=ON \
      -DBUILD_GUI=OFF -DBUILD_TESTS=OFF -DBUILD_BENCH=OFF -DBUILD_TX=OFF \
      -DBUILD_UTIL=ON -DBUILD_WALLET_TOOL=OFF -DBUILD_UTIL_CHAINSTATE=OFF \
      -DWITH_BDB=OFF -DWITH_ZMQ=OFF -DWITH_USDT=OFF -DINSTALL_MAN=OFF \
      -DWITH_CCACHE=ON -DCMAKE_CUDA_COMPILER_LAUNCHER=ccache \
 && cmake --build build --parallel "$(nproc)" \
 && ccache --show-stats \
 && strip --strip-unneeded build/bin/btxd build/bin/btx-cli || true

# ---------- Stage 2: lean CUDA runtime (CUDA_RUNTIME_IMAGE declared up top) ----------
FROM ${CUDA_RUNTIME_IMAGE}
ENV DEBIAN_FRONTEND=noninteractive

# Runtime shared libs the compiled binaries link (libevent / sqlite / boost /
# OpenMP) plus the entrypoint's own tools (curl, jq, python3 for snapshot +
# wallet ops; gnupg is only used by the release-mode fallback). The boost
# *1.83.0 names track Ubuntu 24.04 "Noble" — bump them if CUDA_RUNTIME_IMAGE's
# Ubuntu release changes.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl jq python3 gnupg \
      libevent-2.1-7t64 libevent-core-2.1-7t64 libevent-extra-2.1-7t64 libevent-pthreads-2.1-7t64 \
      libsqlite3-0 libgomp1 \
      libboost-system1.83.0 libboost-filesystem1.83.0 libboost-program-options1.83.0 \
 && rm -rf /var/lib/apt/lists/*

# Compiled 0.32.12 binaries (btxd, btx-cli, btx-matmul-*) + the contrib/ scripts
# the entrypoint drives at run time (mining loop; faststart for release mode).
COPY --from=builder /opt/btx-src/build/bin/ /opt/btx/bin/
COPY --from=builder /opt/btx-src/contrib/   /opt/btx-src/contrib/
ENV PATH=/opt/btx/bin:${PATH}

COPY node/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

VOLUME ["/data"]
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
