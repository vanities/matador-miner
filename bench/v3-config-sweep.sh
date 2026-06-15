#!/usr/bin/env bash
# v3-config-sweep.sh - FORMAL benchmark of v3 solo-throughput CONFIG levers.
#
# Sweeps the tunable knobs one at a time from the current live winner
# (async=1, prefetch-depth=3, prepare-workers=4, gpu-inputs=1, batch-size=2048),
# in v3 nonce-seeded mode, reporting median nonces/s + active watts + nonces/watt.
# Identified by the 2026-06-15 deep dive as the recoverable headroom at v3 (the
# hot kernels are already tapped out / upstreamed; the win is scheduling+occupancy).
#
# SAFE FOR A LIVE RIG: pauses solo GPU mining via the IDLE GATE (btxd STAYS UP ->
# no shielded-rebuild warmup, no lost propagation "social credit"), runs the
# uncontended bench in a throwaway container, and RESUMES on exit. It never
# restarts btxd. Run on the GPU host from the repo dir:
#     bash bench/v3-config-sweep.sh                 # default sweep
#     ITERS=80 BATCHES="4096 8192 16384 32768 65536" bash bench/v3-config-sweep.sh
#
# CAVEAT (read before trusting): the solve-bench exercises the DIGEST path heavily,
# while the dominant LIVE lever (batch-size) acts most on the pre-hash SCAN path.
# So treat bench deltas as DIRECTIONAL. Validate the winning config LIVE (set
# BTX_MATMUL_SOLVE_BATCH_SIZE, watch the batched_nonce_attempts counter delta)
# and run the byte-exact AB gate (btx-matmul-overlap-ab) before committing it.
set -uo pipefail

SVC="${SVC:-btx-miner}"
DATADIR_HOST="${DATADIR_HOST:-$(pwd)/btx-data}"
IMG="${IMG:-btx-miner:local}"
BENCH="${BENCH:-/opt/btx/bin/btx-matmul-solve-bench}"
ITERS="${ITERS:-50}"
ACTIVE_W="${ACTIVE_W:-150}"
BATCHES="${BATCHES:-4096 8192 16384 32768}"
PREFETCHES="${PREFETCHES:-4 6 8}"
WORKERS="${WORKERS:-6 8}"

cli(){ docker exec "$SVC" btx-cli -datadir=/data "$@" 2>/dev/null; }
solvecnt(){ cli getmatmulchallengeprofile | jq -r '.service_profile.runtime_observability.solve_pipeline.batched_nonce_attempts // 0' | tr -dc 0-9; }

command -v nvidia-smi >/dev/null || { echo "nvidia-smi not found"; exit 1; }
docker ps --filter "name=^/${SVC}$" --filter status=running -q | grep -q . || { echo "container '$SVC' not running"; exit 1; }

TIP="$(cli getblockcount | tr -dc 0-9)"; TIP="${TIP:-131800}"
MTP="$(cli getblockchaininfo | jq -r '.mediantime // 0' | tr -dc 0-9)"; MTP="${MTP:-1781540000}"
# v3-representative: per-nonce matrix regen on (nonce-seed/product-digest height 0)
# + parent_mtp seed active, so the bench exercises the real v3 solve path.
V3FLAGS="--n 512 --b 16 --r 8 --backend cuda --nonce-seed-height 0 --product-digest-height 0 --parent-mtp-seed-height 130500 --parent-mtp $MTP --block-height $TIP"

# --- idle-gate pause; ALWAYS resume on exit (btxd is never restarted) ---
resume(){ docker exec "$SVC" rm -f /data/.pause-mining 2>/dev/null; echo "[bench] idle gate cleared -> solo mining resumes (btxd was never restarted)."; }
trap resume EXIT INT TERM
echo "[bench] pausing solo GPU mining via idle gate (btxd stays up)..."
docker exec "$SVC" touch /data/.pause-mining
for _ in $(seq 1 10); do
  a="$(solvecnt)"; sleep 6; b="$(solvecnt)"
  [ "$(( ${b:-0} - ${a:-0} ))" -le 0 ] 2>/dev/null && { echo "[bench] GPU freed (mining paused)."; break; }
  echo "[bench]   waiting for current mining window to end..."
done

pwr_logger(){ while :; do nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits 2>/dev/null | head -1; sleep 0.5; done; }
mean_active_w(){ awk -v t="$ACTIVE_W" '{if($1+0>t){s+=$1;n++}}END{if(n>0)printf"%.0f",s/n;else print"?"}' "$1"; }

run(){ # $1=label, rest=bench flags
  local label="$1"; shift
  local out pf; out="$(mktemp)"; pf="$(mktemp)"
  pwr_logger >"$pf" 2>/dev/null & local pp=$!
  docker run --rm --gpus all -v "$DATADIR_HOST":/data --entrypoint "$BENCH" "$IMG" \
    $V3FLAGS --iterations "$ITERS" "$@" >"$out" 2>/dev/null
  kill "$pp" 2>/dev/null; wait "$pp" 2>/dev/null
  local w med mean eff
  w="$(mean_active_w "$pf")"
  med="$(grep -A6 '"nonces_per_sec"' "$out" | grep '"median"' | grep -oE '[0-9]+\.[0-9]+' | head -1)"
  mean="$(grep -A6 '"nonces_per_sec"' "$out" | grep '"mean"' | grep -oE '[0-9]+\.[0-9]+' | head -1)"
  eff="$(awk -v m="${med:-0}" -v w="${w:-0}" 'BEGIN{if(w>0&&m>0)printf"%.0f",m/w;else print"?"}')"
  local delta=""
  if [ -n "${med:-}" ] && [ -n "${BASE_MED:-}" ]; then delta="$(awk -v m="$med" -v b="$BASE_MED" 'BEGIN{printf"(%.2fx)",m/b}')"; fi
  printf '%-26s %14s %14s %9s %11s %s\n' "$label" "${med:-?}" "${mean:-?}" "${w:-?}" "$eff" "$delta"
  rm -f "$out" "$pf"
  [ -z "${BASE_MED:-}" ] && [ -n "${med:-}" ] && BASE_MED="$med"
}

printf '\n=== v3 config sweep ===  image=%s  iters=%s  height=%s  mtp=%s\n' "$IMG" "$ITERS" "$TIP" "$MTP"
printf 'baseline = current live winner: async=1 prefetch=3 workers=4 gpu-inputs=1 batch=2048\n\n'
printf '%-26s %14s %14s %9s %11s %s\n' "config" "median n/s" "mean n/s" "watts" "n/s per W" "vs base"
printf -- '----------------------------------------------------------------------------------------\n'

BASE_MED=""
run "BASELINE b2048 p3 w4"      --async 1 --prefetch-depth 3 --prepare-workers 4 --gpu-inputs 1 --batch-size 2048
echo "-- batch-size (the #1 candidate lever) --"
for bs in $BATCHES; do run "batch=$bs"       --async 1 --prefetch-depth 3 --prepare-workers 4 --gpu-inputs 1 --batch-size "$bs"; done
echo "-- prefetch-depth (batch 2048) --"
for pd in $PREFETCHES; do run "prefetch=$pd"  --async 1 --prefetch-depth "$pd" --prepare-workers 4 --gpu-inputs 1 --batch-size 2048; done
echo "-- prepare-workers (batch 2048) --"
for wk in $WORKERS; do run "workers=$wk"      --async 1 --prefetch-depth 3 --prepare-workers "$wk" --gpu-inputs 1 --batch-size 2048; done
printf -- '----------------------------------------------------------------------------------------\n'
echo "(median/mean are uncontended bench rates; n/s per W uses active-power mean. vs base = median ratio.)"
echo "Next: validate the best config LIVE (BTX_MATMUL_SOLVE_BATCH_SIZE + counter delta) + byte-exact AB gate before committing."
