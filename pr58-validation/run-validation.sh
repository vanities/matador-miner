#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# run-validation.sh: reproduce the CUDA hardware-validation evidence on a
# Blackwell (sm_120) card. Compiles the two standalone parity harnesses with
# nvcc and runs each under compute-sanitizer. Every section prints the exact
# command before running it, so the captured output is self-documenting.
#
#   nvcc + compute-sanitizer required (CUDA 12.8 used for the published run).
#   Place validate-matmul-patches.cu and validate-sha-windowed-scanner.cu
#   alongside this script, then:  bash run-validation.sh 2>&1 | tee raw-output.txt
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

ARCH="${ARCH:-sm_120}"
run() { echo; echo "\$ $*"; eval "$*"; echo "  (exit=$?)"; }

echo "######################################################################"
echo "# CUDA hardware validation: raw command output"
echo "# host: $(hostname)   date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "######################################################################"

echo; echo "===== 0. environment ====="
run "nvidia-smi -L"
run "nvidia-smi --query-gpu=driver_version,name --format=csv,noheader"
run "nvcc --version | grep -i release"
run "compute-sanitizer --version | head -2"

echo; echo "===== 1. build + run: matmul parity harness ====="
run "nvcc -arch=$ARCH -O3 -o matmul_test validate-matmul-patches.cu"
run "./matmul_test"

echo; echo "===== 2. build + run: SHA windowed-scanner parity harness ====="
run "nvcc -arch=$ARCH -O3 -o sha_test validate-sha-windowed-scanner.cu"
run "./sha_test"

echo; echo "===== 3. compute-sanitizer memcheck (matmul kernels) ====="
run "compute-sanitizer --tool memcheck ./matmul_test 2>&1 | grep -E 'ERROR SUMMARY|invalid|leak|misaligned|out-of'"

echo; echo "===== 4. compute-sanitizer synccheck (matmul __syncthreads barriers) ====="
run "compute-sanitizer --tool synccheck ./matmul_test 2>&1 | grep -E 'ERROR SUMMARY|barrier|divergent'"

echo; echo "===== 5. compute-sanitizer memcheck (scanner kernel) ====="
run "compute-sanitizer --tool memcheck ./sha_test 2>&1 | grep -E 'ERROR SUMMARY|invalid|leak|misaligned|out-of'"

echo; echo "===== 6. compute-sanitizer racecheck (matmul shared-mem tree-reduction) ====="
echo "# BTX_VAL_NO_PERF=1 skips the timing loop: benchmarking under a sanitizer isn't representative"
echo "# (instrumentation inflates and distorts timing), and its ~120 shared-mem kernel re-launches"
echo "# would overrun racecheck's access-record tracker. racecheck then runs the full parity section,"
echo "# exercising every kernel once including FusedOrig/FusedNew (the only kernels declaring __shared__)."
run "BTX_VAL_NO_PERF=1 compute-sanitizer --tool racecheck stdbuf -oL -eL ./matmul_test 2>&1 | grep -E 'RACECHECK SUMMARY|hazard|ALL PASS|returned an error'"

echo; echo "######################################################################"
echo "# done"
echo "######################################################################"
