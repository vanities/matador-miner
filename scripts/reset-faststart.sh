#!/usr/bin/env bash
# Recover a wedged BTX node: wipe chain + shielded state, re-fast-start from the
# assumeutxo snapshot, KEEP the wallet + config (coins preserved), stay pruned.
#
# Use when btxd won't start — e.g. the shielded-state DB was left mid-write by a
# hard kill, which a pruned node can't rebuild (it lacks the old blocks). A clean
# snapshot reload sidesteps that: it re-establishes a consistent state at the
# snapshot height without needing full history.
#
# Run from the repo dir on the GPU host:   bash scripts/reset-faststart.sh
set -euo pipefail

DATADIR_HOST="${DATADIR_HOST:-$(pwd)/btx-data}"
IMAGE="${IMAGE:-btx-miner:local}"

echo "==> Stopping miner..."
docker compose down >/dev/null 2>&1 || true

echo "==> Wiping chain/shielded state (keeping wallet 'miner', btx.conf, binaries)..."
# Done inside a throwaway root container so it can delete the root-owned volume files.
docker run --rm -v "$DATADIR_HOST":/data --entrypoint sh "$IMAGE" -c '
  cd /data || exit 1
  rm -rf blocks chainstate chainstate_snapshot shielded_state indexes \
         mempool.dat fee_estimates.dat peers.dat anchors.dat banlist.json \
         .snapshot_loaded snapshot.dat snapshot.manifest.json debug.log \
         mining-ops .lock .cookie
  echo "kept: $(ls -1 | tr "\n" " ")"
'

echo "==> Re-fast-starting (rebuilds image so the latest entrypoint is used; re-pulls ~347MB snapshot; btx.conf keeps prune=4096)..."
docker compose up -d --build >/dev/null 2>&1

echo "==> Waiting for snapshot load + node near tip (up to ~18 min)..."
synced=0
for i in $(seq 1 220); do
  h=$(docker compose exec -T btx-miner btx-cli -datadir=/data getblockcount 2>/dev/null | tr -dc '0-9' || true)
  if [ -n "${h:-}" ] && [ "${h}" -gt 100000 ] 2>/dev/null; then echo "node up at block $h"; synced=1; break; fi
  sleep 5
done

echo "==> Status:"
docker compose ps --format '{{.Name}}: {{.Status}}'
docker compose exec -T btx-miner btx-cli -datadir=/data getblockchaininfo 2>&1 | grep -iE '"blocks"|"headers"|initialblockdownload|pruned|size_on_disk' || true
docker compose exec -T btx-miner btx-cli -datadir=/data -rpcwallet=miner getbalance 2>&1 || true
docker compose exec -T btx-miner btx-cli -datadir=/data getmininginfo 2>&1 | grep -iE 'should_pause_mining|"reason"|difficulty' || true
[ "$synced" = "1" ] && echo "RESET-OK" || echo "RESET-SLOW (still coming up; re-check shortly)"
