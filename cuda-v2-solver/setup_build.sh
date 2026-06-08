#!/usr/bin/env bash
# Baseline build of btxchain/btx v0.32.2 on pc, in a long-lived CUDA-12.8 devel container
# (deps apt'd once, build dir persisted via mount for fast incremental rebuilds afterward).
set -e
cd ~
rm -rf btx-build-src
echo "[git] cloning v0.32.2..."
git clone --depth 1 --branch v0.32.2 https://github.com/btxchain/btx.git btx-build-src 2>&1 | tail -1
docker rm -f btxbuild 2>/dev/null || true
docker run -d --name btxbuild --gpus all -v "$HOME/btx-build-src:/src" \
  nvidia/cuda:12.8.0-cudnn-devel-ubuntu22.04 sleep infinity >/dev/null
echo "[apt] installing build deps (one-time)..."
docker exec btxbuild bash -c 'apt-get update -q >/tmp/apt.log 2>&1 && apt-get install -y --no-install-recommends build-essential cmake pkg-config python3 git ca-certificates libevent-dev libsqlite3-dev libboost-dev >>/tmp/apt.log 2>&1' \
  || { echo APT_FAIL; docker exec btxbuild tail -15 /tmp/apt.log; exit 1; }
echo "[cmake] configuring..."
docker exec btxbuild bash -c 'cd /src && cmake -B build -DCMAKE_BUILD_TYPE=Release -DBTX_ENABLE_CUDA_EXPERIMENTAL=ON -DBTX_CUDA_ARCHITECTURES=120 -DBTX_CUDA_RUNTIME_LIBRARY=Static -DCUDAToolkit_ROOT=/usr/local/cuda -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc -DBUILD_DAEMON=ON -DBUILD_CLI=ON -DENABLE_WALLET=ON -DWITH_SQLITE=ON -DBUILD_GUI=OFF -DBUILD_TESTS=OFF -DBUILD_BENCH=OFF -DBUILD_TX=OFF -DBUILD_UTIL=ON -DWITH_BDB=OFF -DWITH_ZMQ=OFF -DWITH_USDT=OFF -DINSTALL_MAN=OFF -DWITH_CCACHE=OFF >/tmp/cmake.log 2>&1' \
  || { echo CONFIGURE_FAIL; docker exec btxbuild tail -30 /tmp/cmake.log; exit 1; }
echo "[build] compiling baseline (timing the first full build)..."
S=$(date +%s)
docker exec btxbuild bash -c 'cd /src && cmake --build build --parallel $(nproc) >/tmp/build.log 2>&1' \
  || { echo BUILD_FAIL; docker exec btxbuild tail -45 /tmp/build.log; exit 1; }
echo "BASELINE_OK in $(($(date +%s)-S))s"
docker exec btxbuild ls -la /src/build/bin/btxd /src/build/bin/btx-cli
