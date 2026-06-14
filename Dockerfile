# Isolated BTX GPU solo-miner — COMPILES btxchain/btx from source.
#
# Pinned to the v0.32.9 tag commit, compiled WITH the CUDA MatMul backend.
# Upstream ships GPG-signed cuda13 prebuilts for tagged releases, but we compile
# by choice: it guarantees native sm_120 codegen for the RTX 5090 (the prebuilt's
# embedded archs are unverified) and yields a byte-reproducible build from an
# immutable SHA. To run the signed prebuilt instead, set BTX_INSTALL_MODE=release
# + RELEASE_TAG=v0.32.9 in docker-compose.yml (the entrypoint keeps that path).
#
# 0.32.9 is a btx-node sync point release (tag cut 2026-06-13). It adds an
# empty-block subsidy CONSENSUS rule at HEIGHT 130,000: a consecutive empty
# coinbase-only block may claim at most 50% of the scheduled subsidy (25% for the
# 2nd and later); claiming more is invalid. Plus a 25-tx default template cap
# (fast non-empty path), reorg-parking defaults (warn >3 / park >12 blocks), and
# recovery-exit/mempool/wallet hardening. It does NOT change MatMul consensus
# (seed/digest/verify) and does NOT touch src/cuda/ (only src/metal), so the CUDA
# solver is byte-identical to 0.32.8 and the build stays stock. Because we mine
# SOLO, being on 0.32.9 before height 130,000 avoids producing empty blocks the
# upgraded network would reject. (0.32.8 upstreamed our six PR #58 CUDA patches
# into src/cuda/, so APPLY_LOCAL_PATCHES=0; they carry as upstream through 0.32.9.
# 0.32.7 = validation/chainparams/miner/mempool + assumeutxo; 0.32.6 shielded
# recovery-exit + block-128,000 cleanup; 0.32.5 Metal-only; 0.32.4 operator-safety;
# 0.32.3 on-GPU pre-hash scanner; 0.32.2 block-125,000 shielded-sunset +
# nonce-seed-v2 fork, 2026-06-08.)
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

# Exact upstream commit to compile. dddd2ee1 = the v0.32.9 release tag commit. An
# immutable SHA means every rebuild on every box produces a byte-identical tree.
ARG BTX_SOURCE_REF=dddd2ee1945b987c4a51bf5bb64fae7fb9739c3f
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

# Local optimization patches (PR #58): windowed-SHA scanner + matrix-gen, single-
# reduction + factored compression, and seed/template midstates. These were
# UPSTREAMED into btx 0.32.8's src/cuda/ (matmul_accel.cu / oracle_accel.cu), so
# they are DISABLED by default (APPLY_LOCAL_PATCHES=0). Verified against the 0.32.8
# tree: all six no longer apply because the code they add now ships upstream, which
# is exactly the "build fails LOUDLY -> drop the patch" signal this step was built
# to catch. The .patch files + their on-GPU validators (patches/validate-*.cu) are
# retained for provenance and for re-deriving against any future rev that regresses
# the kernels. To force-apply (e.g. against an older base) build with
# --build-arg APPLY_LOCAL_PATCHES=1.
ARG APPLY_LOCAL_PATCHES=0
COPY patches/ /opt/btx-patches/
RUN if [ "${APPLY_LOCAL_PATCHES}" = "1" ]; then \
      for p in /opt/btx-patches/*.patch; do echo "applying $p"; git apply --verbose "$p"; done; \
    else echo "APPLY_LOCAL_PATCHES=0 - patches upstreamed in 0.32.8, building stock"; fi

# Configure with the CUDA MatMul backend (see upstream doc/build-unix.md):
#   - node + cli + wallet(sqlite). BUILD_UTIL=ON only because the btx-matmul-*
#     diagnostic + solve-bench tools are gated behind it in src/CMakeLists.txt.
#     No GUI/tests/bench/tx/bdb/zmq.
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
      -DBUILD_UTIL=ON -DBUILD_WALLET_TOOL=OFF -DBUILD_UTIL_CHAINSTATE=OFF \
      -DWITH_BDB=OFF -DWITH_ZMQ=OFF -DWITH_USDT=OFF -DINSTALL_MAN=OFF \
      -DWITH_CCACHE=OFF \
 && cmake --build build --parallel "$(nproc)" \
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

# Compiled 0.32.9 binaries (btxd, btx-cli, btx-matmul-*) + the contrib/ scripts
# the entrypoint drives at run time (mining loop; faststart for release mode).
COPY --from=builder /opt/btx-src/build/bin/ /opt/btx/bin/
COPY --from=builder /opt/btx-src/contrib/   /opt/btx-src/contrib/
ENV PATH=/opt/btx/bin:${PATH}

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

VOLUME ["/data"]
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
