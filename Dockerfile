# Isolated BTX GPU solo-miner — COMPILES btxchain/btx from source.
#
# Pinned to the v0.32.6 tag commit, compiled WITH the CUDA MatMul backend.
# Upstream ships GPG-signed cuda13 prebuilts for tagged releases, but we compile
# by choice: it guarantees native sm_120 codegen for the RTX 5090 (the prebuilt's
# embedded archs are unverified) and yields a byte-reproducible build from an
# immutable SHA. To run the signed prebuilt instead, set BTX_INSTALL_MODE=release
# + RELEASE_TAG=v0.32.6 in docker-compose.yml (the entrypoint keeps that path).
#
# 0.32.6 is a CONSENSUS-side hardening point release: it tightens shielded
# recovery-exit + transparent-exit validation and adds a block-128,000 cleanup
# boundary for proofless transparent-funded V2_SEND public-flow shielding (touches
# validation.cpp, chainparams, consensus/params.h, the shielded/ path, miner.cpp).
# Worth taking so a validating node stays on current consensus rules. It does NOT
# touch src/cuda/, so all six local patches apply byte-for-byte unchanged.
# (0.32.5 was an Apple-Metal-only digest fix, a no-op here; 0.32.4 was
# operator-safety hardening; 0.32.3 added the on-GPU pre-hash scanner; 0.32.2 was
# the mandatory block-125,000 shielded-sunset + nonce-seed-v2 fork, 2026-06-08.)
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

# Exact upstream commit to compile. 0e692ee = the v0.32.6 release tag commit. An
# immutable SHA means every rebuild on every box produces a byte-identical tree.
ARG BTX_SOURCE_REF=0e692ee2024b01fc4bede3d4834d7263f3f4ce7a
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

# Local optimization patches on top of the pinned upstream commit. Applied with
# `git apply` (NOT a file-overlay) so a future BTX rev that moves this code makes
# the build fail LOUDLY — the signal to re-derive or drop the patch. Each patch is
# byte-exact-validated on-GPU before deploy (see patches/validate-*.cu).
#   sha-windowed-scanner.patch — windowed SHA-256 (16-word sliding schedule) in the
#   CUDA nonce-seed pre-hash scanner (oracle_accel.cu). ~2x faster scanner kernel,
#   measured +5.4% end-to-end (validated 200k nonces, 0 mismatches).
#   sha-windowed-matrixgen.patch — the same windowed-SHA transform applied to
#   matmul_accel.cu's DUPLICATE of that SHA code, which runs even hotter: the
#   per-candidate GenerateBaseMatrixFromSeedBatchKernel (2 x n^2 = 524k
#   compressions per candidate). ~3.1x faster matrix-gen kernel (validated 2.1M
#   elements + 65k retry/fallback edge cases, 0 mismatches).
#   fused-single-reduction.patch — in the live PRODUCT_FINAL_BLOCKS digest mode,
#   the fused product kernel tree-reduced across the block once per ell (32x per
#   output word); mod-field distributivity lets one register-resident length-n dot
#   product + a single block reduction produce the identical canonical word.
#   ~1.5-2x faster fused kernel (validated 4096 words vs stock kernel AND a CPU
#   reference, 0 mismatches). Retained as the fallback path for shapes the
#   factored patch below doesn't cover (n % 32 != 0) and for prefix mode.
#   factored-compression.patch — same distributivity, taken further: compress
#   weights fold into the RHS once per request (D[j][x][m] = sum_y W[x,y] *
#   B'[m][j*b+y]), then one warp per 2x2 word tile contracts A' against D. Cuts
#   per-candidate product MACs n^3=134M -> ~12.6M (~10.6x); kernel measured ~6.4x
#   vs the single-reduction fused kernel. Byte-exact (validated 4096 words vs the
#   stock fused kernel, 0 mismatches). Non-prefix mode only; adds a ~1 MiB/request
#   device staging buffer per workspace slot.
#   matrixgen-seed-midstate.patch — the matrix-gen SHA hashes seed||index with a
#   fixed seed in w[0..7], so rounds 0-7 are identical across all 2^18 elements of
#   a matrix. A tiny precompute kernel computes that midstate once per seed; the
#   gen kernel loads it as scalars and resumes at round 8 (no per-block barrier —
#   a shared-memory hoist was 3x SLOWER; the 2-kernel form is the win). ~12% faster
#   matrix-gen kernel, +5.6% end-to-end in v2 mode (validated 2.1M elements, 0
#   mismatches; ~2^-31 retry/fallback defers to the full path).
#   Build stock instead with --build-arg APPLY_LOCAL_PATCHES=0.
ARG APPLY_LOCAL_PATCHES=1
COPY patches/ /opt/btx-patches/
RUN if [ "${APPLY_LOCAL_PATCHES}" = "1" ]; then \
      for p in /opt/btx-patches/*.patch; do echo "applying $p"; git apply --verbose "$p"; done; \
    else echo "APPLY_LOCAL_PATCHES=0 — building stock upstream 0.32.3"; fi

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

# Compiled 0.32.3 binaries (btxd, btx-cli, btx-matmul-*) + the contrib/ scripts
# the entrypoint drives at run time (mining loop; faststart for release mode).
COPY --from=builder /opt/btx-src/build/bin/ /opt/btx/bin/
COPY --from=builder /opt/btx-src/contrib/   /opt/btx-src/contrib/
ENV PATH=/opt/btx/bin:${PATH}

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

VOLUME ["/data"]
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
