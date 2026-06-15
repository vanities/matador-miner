#!/usr/bin/env bash
# validate.sh - the btx-dev-requested CUDA CORRECTNESS gate, as part of the bench.
#
# Runs numair's hardware-validation suite (pr58-validation/run-validation.sh):
#   - byte-exact CUDA-vs-CPU parity: matmul kernels + SHA windowed-scanner
#   - compute-sanitizer memcheck (matmul + scanner)
#   - compute-sanitizer synccheck (matmul __syncthreads barriers)
#   - compute-sanitizer racecheck (matmul shared-mem, BTX_VAL_NO_PERF gate)
# Pass = parity all-PASS + every sanitizer ERROR/RACECHECK SUMMARY == 0.
#
# This is the correctness half of "bench": throughput (v3-config-sweep.sh) tells
# you if a kernel change is FASTER; this tells you if it's still CORRECT + clean.
# MANDATORY before deploying any kernel change or the matador-miner. The btx devs
# (numair) asked us to formulate exactly this; it now gates every build.
#
# Runs in a CUDA devel container (nvcc + compute-sanitizer), idle-gate-paused so
# btxd stays up (no warmup, no lost social credit). On the GPU host:
#   bash bench/validate.sh          # validate the committed pr58-validation harnesses
#   VDIR=/path/to/validators bash bench/validate.sh   # point at patched harnesses
set -uo pipefail

SVC="${SVC:-btx-miner}"
DEVEL="${DEVEL:-nvidia/cuda:13.0.0-devel-ubuntu24.04}"
ARCH="${ARCH:-sm_120}"
VDIR="${VDIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/pr58-validation}"

[ -f "$VDIR/run-validation.sh" ] || { echo "no run-validation.sh in $VDIR"; exit 1; }
command -v nvidia-smi >/dev/null || { echo "nvidia-smi not found (run on the GPU host)"; exit 1; }

# idle-gate pause + guaranteed resume (btxd never restarts)
cli(){ docker exec "$SVC" btx-cli -datadir=/data "$@" 2>/dev/null; }
resume(){ docker exec "$SVC" rm -f /data/.pause-mining 2>/dev/null && echo "[validate] mining resumed (btxd untouched)"; }
if docker ps --filter "name=^/${SVC}$" --filter status=running -q | grep -q .; then
  trap resume EXIT INT TERM
  docker exec "$SVC" touch /data/.pause-mining && echo "[validate] solo mining paused via idle gate"
  for _ in $(seq 1 10); do
    a=$(cli getmatmulchallengeprofile | jq -r '.service_profile.runtime_observability.solve_pipeline.batched_nonce_attempts // 0' 2>/dev/null | tr -dc 0-9)
    sleep 6
    b=$(cli getmatmulchallengeprofile | jq -r '.service_profile.runtime_observability.solve_pipeline.batched_nonce_attempts // 0' 2>/dev/null | tr -dc 0-9)
    [ "$(( ${b:-0} - ${a:-0} ))" -le 0 ] 2>/dev/null && { echo "[validate] GPU free"; break; }
  done
fi

echo "[validate] running the parity + compute-sanitizer suite in $DEVEL (arch=$ARCH)..."
out=$(docker run --rm --gpus all -v "$VDIR":/v -w /v -e ARCH="$ARCH" "$DEVEL" bash run-validation.sh 2>&1)
echo "$out"

echo
echo "================ VALIDATION SUMMARY ================"
# Parity: the harnesses print PASS/FAIL lines; sanitizers print ERROR/RACECHECK SUMMARY.
fails=$(printf '%s\n' "$out" | grep -ciE 'FAIL|mismatch[^e]|ERROR SUMMARY: [1-9]|hazard|RACECHECK SUMMARY: [1-9]|returned an error' || true)
passes=$(printf '%s\n' "$out" | grep -ciE 'PASS|ERROR SUMMARY: 0 errors|ALL PASS|RACECHECK SUMMARY: 0' || true)
echo "pass-markers=$passes  fail-markers=$fails"
if [ "${fails:-0}" -eq 0 ] && [ "${passes:-0}" -gt 0 ]; then
  echo "RESULT: PASS  (byte-exact parity + sanitizer-clean) - safe to deploy"
  exit 0
else
  echo "RESULT: FAIL or INCONCLUSIVE - DO NOT deploy; inspect the suite output above"
  exit 1
fi
