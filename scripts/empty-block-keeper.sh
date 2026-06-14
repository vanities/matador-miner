#!/usr/bin/env bash
# empty-block-keeper.sh - BTX empty-block subsidy insurance (optimization idea #1).
#
# During the penalty window [130000, 132000) a coinbase-only block (nTx==1) is
# penalized: base/2, or base/4 if it follows another empty block (the STRICT
# regime at height >=130500). VERIFIED LIVE 2026-06-14: block 130927 (nTx==1)
# paid 10 BTX where a normal block pays 20. This keeper keeps at least
# MIN_MEMPOOL transaction(s) in the mempool at all times, so any block WE mine
# carries an extra tx (nTx>=2) and claims the FULL subsidy instead of half.
#
# It self-spends a tiny amount from our own wallet. Cost is a low fee (often
# recovered when we are the one who mines the tx). Self-time-boxed: it exits
# automatically once the chain reaches END_HEIGHT (penalty over, no more point).
#
# Run on pc from the compose dir, detached so it survives the ssh session:
#   cd ~/git/btx-miner && mkdir -p ops-logs
#   setsid bash scripts/empty-block-keeper.sh >> ops-logs/empty-block-keeper.log 2>&1 < /dev/null &
# (ops-logs/ is host-owned; btx-data/ is container-owned root, not host-writable)
#
# Stop it:  pkill -f empty-block-keeper.sh
set -uo pipefail

END_HEIGHT="${END_HEIGHT:-132000}"   # penalty ends here (BTX_V03211_HARDENING_HEIGHT); keeper auto-exits
MIN_MEMPOOL="${MIN_MEMPOOL:-1}"      # keep at least this many txs in the mempool
SEND_AMT="${SEND_AMT:-0.01}"         # tiny self-spend amount (BTX)
TX_FEE="${TX_FEE:-0.00005}"          # low wallet fee (BTX/kB), safely above min-relay, bounds cost
SLEEP="${SLEEP:-20}"                 # poll interval (seconds)
WALLET="${WALLET:-miner}"
HEARTBEAT="${HEARTBEAT:-30}"         # emit an 'ok' heartbeat line every N idle cycles

CLI=(docker compose exec -T btx-miner btx-cli -datadir=/data)
WCLI=(docker compose exec -T btx-miner btx-cli -datadir=/data -rpcwallet="$WALLET")
log() { echo "[$(date +%FT%T)] [keeper] $*"; }

# Low, bounded fee. If the node rejects it as too low, sends fall back to the
# wallet default (we will see TOPUP lines either way).
"${WCLI[@]}" settxfee "$TX_FEE" >/dev/null 2>&1 || true

# One dedicated, reused address to limit address/UTXO sprawl over the window.
KEEP_ADDR="$("${WCLI[@]}" getnewaddress empty-block-keeper 2>/dev/null | tr -dc 'a-zA-Z0-9')"
if [ -z "$KEEP_ADDR" ]; then log "FATAL: could not get a keeper address (is wallet '$WALLET' loaded?)"; exit 1; fi
log "start: window<$END_HEIGHT min_mempool=$MIN_MEMPOOL amt=$SEND_AMT fee=$TX_FEE/kB addr=$KEEP_ADDR"

cyc=0
while :; do
  cyc=$((cyc+1))
  H="$("${CLI[@]}" getblockcount 2>/dev/null | tr -dc 0-9)"
  if [ -z "$H" ]; then log "rpc down, retry in ${SLEEP}s"; sleep "$SLEEP"; continue; fi
  if [ "$H" -ge "$END_HEIGHT" ]; then log "height $H >= $END_HEIGHT: penalty window closed, keeper done"; break; fi

  MS="$("${CLI[@]}" getmempoolinfo 2>/dev/null | jq -r '.size // 0' | tr -dc 0-9)"; MS="${MS:-0}"
  if [ "$MS" -lt "$MIN_MEMPOOL" ]; then
    TXID="$("${WCLI[@]}" sendtoaddress "$KEEP_ADDR" "$SEND_AMT" 2>/dev/null | tr -dc 'a-f0-9')"
    if [ -n "$TXID" ]; then
      log "topup: mempool=$MS<$MIN_MEMPOOL sent $SEND_AMT tx=${TXID:0:16} (h=$H, ~$((END_HEIGHT-H)) blocks left)"
    else
      log "TOPUP FAILED h=$H mempool=$MS (wallet locked / no funds / fee too low?)"
    fi
  elif [ $((cyc % HEARTBEAT)) -eq 0 ]; then
    log "ok: mempool=$MS h=$H (~$((END_HEIGHT-H)) blocks left in window)"
  fi
  sleep "$SLEEP"
done
