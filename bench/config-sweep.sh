#!/usr/bin/env bash
# Sweep solver PIPELINE config knobs (async prepare, batch size, prefetch,
# prepare workers) in v2 nonce-seed mode. These tune CPU<->GPU overlap and
# saturation — live levers that touch NO consensus code. Winners get baked into
# docker-compose.yml env. Pauses the miner; restores it at the end.
set -uo pipefail
SVC="${SVC:-btx-miner}"
IMAGE="${IMAGE:-btx-miner:local}"
DATADIR_HOST="${DATADIR_HOST:-$(pwd)/btx-data}"
BENCH="/opt/btx/bin/btx-matmul-solve-bench"
ITERS="${ITERS:-100}"
HEIGHT="${HEIGHT:-$(docker exec "$SVC" btx-cli -datadir=/data getblockcount 2>/dev/null || echo 126240)}"
V2="--block-height $HEIGHT --nonce-seed-height 0 --product-digest-height 0"

echo "Pausing miner..."; docker compose stop >/dev/null 2>&1 || true

run() {  # remaining args = extra bench flags
  timeout 200 docker run --rm --gpus all -v "$DATADIR_HOST":/data --entrypoint "$BENCH" "$IMAGE" \
    --backend cuda --n 512 --b 16 --r 8 --iterations "$ITERS" $V2 "$@" 2>/dev/null \
    | grep -A6 '"nonces_per_sec"' | grep '"median"' | grep -oE '[0-9]+\.[0-9]+' | head -1
}

printf '\nv2 config sweep  ·  %s  ·  height=%s  ·  iters=%s\n' "$IMAGE" "$HEIGHT" "$ITERS"
printf -- '----------------------------------------------------\n'
printf '%-40s %12s\n' 'config' 'median n/s'
base=$(run); printf '%-40s %12s\n' 'baseline (image defaults)' "${base:-ERR}"
for cfg in \
  "--async 1" \
  "--batch-size 4096" \
  "--batch-size 8192" \
  "--prefetch-depth 2" \
  "--prefetch-depth 3" \
  "--async 1 --prefetch-depth 2" \
  "--async 1 --batch-size 4096 --prefetch-depth 2" \
  "--prepare-workers 8" \
  "--async 1 --prepare-workers 8 --prefetch-depth 2 --batch-size 4096" \
  "--pool-slots 8" \
; do
  v=$(run $cfg)
  d=""
  [ -n "$v" ] && [ -n "${base:-}" ] && d=$(awk -v a="$v" -v b="$base" 'BEGIN{printf "%+.1f%%", (a/b-1)*100}')
  printf '%-40s %12s   %s\n' "$cfg" "${v:-ERR}" "$d"
done
printf -- '----------------------------------------------------\n'
echo "Restarting miner..."; docker compose up -d >/dev/null 2>&1 || true
