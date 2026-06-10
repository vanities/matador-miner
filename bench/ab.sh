#!/usr/bin/env bash
# A/B the MatMul solver across images in v2 NONCE-SEED mode — the mode that
# represents LIVE post-125,000 mining (every nonce regenerates its matrices).
#
# The default solve-bench reuses one seed and CACHES matrix generation, so it
# measures mostly the matrix product and overstates live gains ~3-4x. Always
# compare images with THIS script, not the bare bench.
#
#   sudo not needed.  Run on the GPU host from the repo dir:
#     bash bench/ab.sh                     # compares the standard image ladder
#     IMAGES="btx-miner:0323 btx-miner:local" bash bench/ab.sh
#     ITERS=200 CONTENDED=1 bash bench/ab.sh   # don't stop the miner (noisier)
#
# Tunables (env): IMAGES  ITERS=100  CONTENDED=0  HEIGHT=<auto>  RESTART_MINER=1
set -uo pipefail

SVC="${SVC:-btx-miner}"
DATADIR_HOST="${DATADIR_HOST:-$(pwd)/btx-data}"
BENCH="${BENCH:-/opt/btx/bin/btx-matmul-solve-bench}"
ITERS="${ITERS:-100}"
CONTENDED="${CONTENDED:-0}"        # 1 = leave the miner running (ratio still valid, more noise)
RESTART_MINER="${RESTART_MINER:-1}"
# Default ladder: 0 -> 1 -> 3 -> 4 -> 5 patches. Override with IMAGES=...
IMAGES="${IMAGES:-btx-miner:0323 btx-miner:prev btx-miner:prev2 btx-miner:prev3 btx-miner:local}"

command -v nvidia-smi >/dev/null || { echo "nvidia-smi not found"; exit 1; }

# v2 activation flags: force nonce-seed + product-digest active at the bench
# height so matrices regenerate per nonce exactly like live mining.
HEIGHT="${HEIGHT:-}"
if [ -z "$HEIGHT" ]; then
  HEIGHT=$(docker exec "$SVC" btx-cli -datadir=/data getblockcount 2>/dev/null || echo 126000)
fi
V2_FLAGS="--block-height $HEIGHT --nonce-seed-height 0 --product-digest-height 0"

if [ "$CONTENDED" != "1" ]; then
  echo "Pausing miner for clean numbers (CONTENDED=1 to skip)..."
  docker compose stop >/dev/null 2>&1 || true
fi

# Log GPU power every 0.5s to a file for the whole run; the caller averages only
# the ACTIVE samples (>150 W) so a fast bench's idle tail doesn't drag the mean.
ACTIVE_W="${ACTIVE_W:-150}"
power_logger() {
  while :; do
    nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits 2>/dev/null | head -1
    sleep 0.5
  done
}
mean_active_power() {  # $1 = sample file
  awk -v thr="$ACTIVE_W" '{ if ($1+0 > thr) { s+=$1; n++ } } END{ if(n>0) printf "%.0f", s/n; else print "?" }' "$1"
}

printf '\nv2 nonce-seed mode  ·  n=512 b=16 r=8  ·  iters=%s  ·  height=%s\n' "$ITERS" "$HEIGHT"
printf -- '------------------------------------------------------------------------\n'
printf '%-20s %14s %14s %12s %10s\n' "image" "median n/s" "mean n/s" "watts" "n/s per W"
printf -- '------------------------------------------------------------------------\n'

first_med=""
for IMG in $IMAGES; do
  if ! docker image inspect "$IMG" >/dev/null 2>&1; then
    printf '%-20s %14s\n' "$IMG" "(missing)"; continue
  fi
  # Run the bench in the background; log power across the WHOLE run in parallel.
  out_file=$(mktemp); pwr_file=$(mktemp)
  power_logger >"$pwr_file" 2>/dev/null &
  pwr_pid=$!
  docker run --rm --gpus all -v "$DATADIR_HOST":/data --entrypoint "$BENCH" "$IMG" \
    --backend cuda --n 512 --b 16 --r 8 --iterations "$ITERS" $V2_FLAGS >"$out_file" 2>/dev/null &
  run_pid=$!
  wait "$run_pid"
  kill "$pwr_pid" 2>/dev/null; wait "$pwr_pid" 2>/dev/null
  watts=$(mean_active_power "$pwr_file"); rm -f "$pwr_file"
  block=$(grep -A6 '"nonces_per_sec"' "$out_file")
  med=$(printf '%s' "$block"  | grep '"median"' | grep -oE '[0-9]+\.[0-9]+' | head -1)
  mean=$(printf '%s' "$block" | grep '"mean"'   | grep -oE '[0-9]+\.[0-9]+' | head -1)
  rm -f "$out_file"
  eff=$(awk -v m="${med:-0}" -v w="${watts:-0}" 'BEGIN{ if(w>0&&m>0) printf "%.0f", m/w; else print "?" }')
  delta=""
  if [ -n "${med:-}" ]; then
    if [ -z "$first_med" ]; then first_med="$med";
    else delta=$(awk -v m="$med" -v f="$first_med" 'BEGIN{ printf "(%.2fx)", m/f }'); fi
  fi
  printf '%-20s %14s %14s %12s %10s %s\n' "$IMG" "${med:-?}" "${mean:-?}" "${watts:-?}" "$eff" "$delta"
done

printf -- '------------------------------------------------------------------------\n'
echo "(x) = speedup vs the first image. n/s per W = efficiency at current power state."

if [ "$CONTENDED" != "1" ] && [ "$RESTART_MINER" = "1" ]; then
  echo "Restarting miner..."
  docker compose up -d >/dev/null 2>&1 || true
fi
