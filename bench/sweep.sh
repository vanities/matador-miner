#!/usr/bin/env bash
# Sweep GPU power limits and measure BTX MatMul solver throughput at each.
#
# Needs root (for `nvidia-smi -pl`):   sudo bash bench/sweep.sh
# Run from the repo dir on the GPU host. Pauses the compose miner for clean
# (uncontended) numbers, then restores the default power limit.
#
# Tunables (env): LIMITS="600 520 460 400"  ITERS=100  DEFAULT_PL=575  RESTART_MINER=1
set -euo pipefail

LIMITS=(${LIMITS:-600 575 520 460 440 400})
IMAGE="${IMAGE:-btx-miner:local}"
DATADIR_HOST="${DATADIR_HOST:-$(pwd)/btx-data}"
BENCH="${BENCH:-/opt/btx/bin/btx-matmul-solve-bench}"   # compiled into the image (source build)
ITERS="${ITERS:-100}"
DEFAULT_PL="${DEFAULT_PL:-575}"
RESTART_MINER="${RESTART_MINER:-0}"

command -v nvidia-smi >/dev/null || { echo "nvidia-smi not found"; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo) — nvidia-smi -pl needs it"; exit 1; }

echo "Pausing miner for clean benches..."
docker compose stop >/dev/null 2>&1 || true

printf '\n%-7s %-15s %-15s %s\n' "Watts" "median n/s" "mean n/s" "nonces/s per W"
printf -- '-------------------------------------------------------\n'
for W in "${LIMITS[@]}"; do
  if ! nvidia-smi -pl "$W" >/dev/null 2>&1; then
    printf '%-7s %s\n' "$W" "(could not set — valid range is 400-600 W)"; continue
  fi
  sleep 2
  out=$(timeout 220 docker run --rm --gpus all -v "$DATADIR_HOST":/data \
        --entrypoint "$BENCH" "$IMAGE" \
        --backend cuda --n 512 --b 16 --r 8 --iterations "$ITERS" 2>/dev/null || true)
  block=$(printf '%s' "$out" | grep -A6 '"nonces_per_sec"')
  med=$(printf '%s' "$block"  | grep '"median"' | grep -oE '[0-9]+\.[0-9]+' | head -1)
  mean=$(printf '%s' "$block" | grep '"mean"'   | grep -oE '[0-9]+\.[0-9]+' | head -1)
  eff=$(awk -v m="${med:-0}" -v w="$W" 'BEGIN{ if(w>0 && m>0) printf "%.1f", m/w; else printf "?" }')
  printf '%-7s %-15s %-15s %s\n' "$W" "${med:-?}" "${mean:-?}" "$eff"
done

echo; echo "Restoring power limit to ${DEFAULT_PL} W..."
nvidia-smi -pl "$DEFAULT_PL" >/dev/null 2>&1 || true
if [ "$RESTART_MINER" = "1" ]; then echo "Restarting miner..."; docker compose up -d >/dev/null 2>&1 || true; fi
echo "Done. (Higher nonces/s-per-W = more efficient; expect the knee around 75-85%.)"
