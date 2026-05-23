#!/usr/bin/env bash
# One-shot BTX miner dashboard. Run on the GPU host from the repo dir:
#   bash scripts/stats.sh        (or:  make stats)
set -uo pipefail
COMPOSE="${COMPOSE:-docker compose}"
SVC="${SVC:-btx-miner}"
WALLET="${WALLET:-miner}"

cyan(){ printf '\033[1;36m%s\033[0m\n' "$*"; }

cyan "── BTX MINER ──  $(date '+%Y-%m-%d %H:%M:%S')"
status=$($COMPOSE ps --format '{{.Status}}' 2>/dev/null | head -1)
printf 'container : %s\n' "${status:-NOT RUNNING}"

if [ -n "${status:-}" ]; then
  $COMPOSE exec -T "$SVC" sh 2>/dev/null <<EOF
q() { btx-cli -datadir=/data "\$@"; }
q -rpcwallet=$WALLET getwalletinfo 2>/dev/null | jq -r '"balance   : \(.balance) + \(.immature_balance) immature = \(.balance + .immature_balance) BTX   (\(.txcount) blocks)"'
q getblockchaininfo 2>/dev/null | jq -r '"height    : \(.blocks) / \(.headers)   IBD=\(.initialblockdownload)"'
q getmininginfo 2>/dev/null | jq -r '"difficulty: \(.difficulty)\nnet h/s   : \(.networkhashps|floor)\nmining    : paused=\(.chain_guard.should_pause_mining)  \(.chain_guard.reason)  peers=\(.chain_guard.peer_count)  near_tip=\(.chain_guard.near_tip_peers)"'
EOF
fi

cyan "GPU"
nvidia-smi --query-gpu=utilization.gpu,utilization.memory,clocks.current.sm,clocks.max.sm,power.draw,power.limit,temperature.gpu --format=csv,noheader 2>/dev/null \
  | awk -F', *' '{printf "util %s | mem %s | clk %s/%s | pwr %s/%s | %s\n",$1,$2,$3,$4,$5,$6,$7}'
printf 'nonce/s   : ~121K @460W (solve-bench reference; no live meter)\n'
