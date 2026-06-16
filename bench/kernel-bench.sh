#!/usr/bin/env bash
# kernel-bench.sh - measure the freshly-built CUDA kernel on the v3 nonce-seeded
# path cleanly + deterministically (uncontended solve-bench, no btxd sync needed).
# This is the measurement half of the optimize loop: edit kernel -> build.sh ->
# kernel-bench.sh -> compare attempts/s -> validate.sh (byte-exact) -> keep/revert.
#
# Pauses mining (idle gate) for the bench, resumes after. Run ON pc from the repo
# root (~/git/matador-miner).
#
#   bash bench/kernel-bench.sh                 # async=0 (serial) baseline
#   TRIES=400000 bash bench/kernel-bench.sh    # longer run = tighter number
#   ASYNC=1 bash bench/kernel-bench.sh         # measure with the overlap pipeline on
set -uo pipefail
SVC="${SVC:-btx-miner}"
DEV_BIN="${DEV_BIN:-/tmp/matador-src/build/bin/btx-matmul-solve-bench}"
TRIES="${TRIES:-300000}"
ASYNC="${ASYNC:-0}"
PARENT_MTP="${PARENT_MTP:-1781450513}"   # mediantime of a real v3 parent (deterministic seed)
C="docker compose"

[ -f "$DEV_BIN" ] || { echo "[bench] no solve-bench at $DEV_BIN - run private/matador-miner/build.sh first"; exit 1; }
$C ps >/dev/null 2>&1 || { echo "[bench] run this from the repo dir (~/git/matador-miner)"; exit 1; }

echo "[bench] copying freshly-built solve-bench into $SVC ..."
$C cp "$DEV_BIN" "$SVC":/usr/local/bin/solve-bench-dev >/dev/null

echo "[bench] pausing mining (idle gate; btxd stays up, no warmup) for a clean GPU bench ..."
$C exec -T "$SVC" touch /data/.pause-mining; sleep 3
# guarantee mining resumes even if the bench errors out
trap '$C exec -T "$SVC" rm -f /data/.pause-mining >/dev/null 2>&1; echo "[bench] mining resumed"' EXIT

echo "[bench] v3 solve-bench: tries=$TRIES async=$ASYNC gpu_inputs=1 backend=cuda"
$C exec -T "$SVC" solve-bench-dev \
  --backend cuda --gpu-inputs 1 \
  --block-height 131000 --nonce-seed-height 130500 --parent-mtp-seed-height 130500 \
  --parent-mtp "$PARENT_MTP" --product-digest-height 130000 \
  --tries "$TRIES" --async "$ASYNC" 2>&1 \
  | grep -iE -A3 "nonces_per_sec|elapsed_s|batched_(nonce|digest)" | head -24
