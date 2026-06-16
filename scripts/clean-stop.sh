#!/usr/bin/env bash
# clean-stop.sh - wait for a SAFE window, then stop btxd CLEANLY (never kill -9).
#
# Per shib: a clean stop WHILE CAUGHT UP -> ~30s shielded fast-restore next boot,
# instead of a ~15min from-genesis RebuildShieldedState. A kill -9 (or a stop that
# SIGKILLs mid-flush) truncates the shielded-state write AND leaves stale LOCKs
# (blocks/.lock, leveldb LOCK, shielded_state LOCK) that block the next start. So:
#   1) WAIT for the node to be caught up to the network + well-peered + healthy
#      (not mid-reorg, not stale-tip partitioned), then
#   2) `docker compose stop -t 120` so the entrypoint's graceful_stop can flush.
#
# Use before ANY deliberate restart/upgrade.
#   bash scripts/clean-stop.sh                  # wait for window, then clean stop
#   ACTION=restart bash scripts/clean-stop.sh   # ...then start again (same container)
#   MIN_PEERS=4 MAX_WAIT_MIN=30 bash scripts/clean-stop.sh
set -uo pipefail

SVC="${SVC:-btx-miner}"
MIN_PEERS="${MIN_PEERS:-3}"        # require this many near-tip peers (good propagation)
MAX_WAIT_MIN="${MAX_WAIT_MIN:-20}" # give up waiting for a window after this long
MAX_TIP_AGE="${MAX_TIP_AGE:-1800}" # informational: flag the tip as "fresh" if the best
                                   # block is younger than this (s). NOT a hard gate -
                                   # a real network-wide dry spell makes EVERY node's tip
                                   # old while still being at the tip, so we gate on
                                   # reason=healthy (peer-median verdict), not tip age.
ACTION="${ACTION:-stop}"           # stop | restart
EXPLORER="${EXPLORER:-https://explorer.minebtx.com/api/blocks/tip/height}"
CLI=(docker compose exec -T "$SVC" btx-cli -datadir=/data)
log(){ echo "[$(date +%FT%T)] [clean-stop] $*"; }

is_safe() {
  local bi mi H HD IBD T ntp reason canon now tip_age fresh
  bi="$("${CLI[@]}" getblockchaininfo 2>/dev/null)" || return 1
  H="$(echo "$bi"  | jq -r '.blocks  // 0' 2>/dev/null)"
  HD="$(echo "$bi" | jq -r '.headers // 0' 2>/dev/null)"
  IBD="$(echo "$bi" | jq -r '.initialblockdownload // true' 2>/dev/null)"
  T="$(echo "$bi"  | jq -r '.time // 0' 2>/dev/null)"            # tip block timestamp
  mi="$("${CLI[@]}" getmininginfo 2>/dev/null)"
  ntp="$(echo "$mi" | jq -r 'first(.. | objects | select(has("near_tip_peers")) | .near_tip_peers)' 2>/dev/null | tr -dc 0-9)"; ntp="${ntp:-0}"
  reason="$(echo "$mi" | jq -r 'first(.. | objects | select(has("reason")) | .reason)' 2>/dev/null)"
  canon="$(curl -fsS --max-time 6 "$EXPLORER" 2>/dev/null | tr -dc 0-9)"
  now="$(date +%s)"
  tip_age=$(( now - ${T:-now} )); [ "$tip_age" -lt 0 ] 2>/dev/null && tip_age=0
  fresh="no"; [ "$tip_age" -le "$MAX_TIP_AGE" ] 2>/dev/null && fresh="yes"
  log "h=$H/$HD ibd=$IBD tip_age=${tip_age}s(fresh=$fresh) near_tip_peers=$ntp reason=${reason:-?} canonical=${canon:-n/a}"

  # We DELIBERATELY do NOT gate on .initialblockdownload. With an assumeutxo
  # fast-start snapshot, the node keeps initialblockdownload=true while the
  # from-genesis BACKGROUND validation chainstate grinds - even though the ACTIVE
  # mining tip is fully caught up to the network. A clean stop only needs the
  # ACTIVE tip at the network edge (mining runs off it); the background chainstate
  # flushes cleanly regardless. So we gate on DETERMINISTIC at-tip facts instead
  # (this is what cost ~13min of false "still syncing" waiting on the 0.32.12 deploy):
  [ -n "$H" ] && [ "$H" -ge "$((HD-1))" ] 2>/dev/null || return 1  # blocks caught up to our headers
  [ "$ntp" -ge "$MIN_PEERS" ] 2>/dev/null || return 1             # well-peered (propagation)
  [ "$reason" = "healthy" ] || return 1                            # node's mining_guard: not behind the peer
                                                                   # median / not paused / not mid-reorg. THIS is
                                                                   # the deterministic "at network tip" verdict -
                                                                   # true even while IBD background-syncs.
  [ -n "$canon" ] && { [ "$H" -ge "$((canon-2))" ] 2>/dev/null || return 1; }  # explorer cross-check, when reachable
  return 0
}

log "waiting for a clean-stop window (caught up to network + >=${MIN_PEERS} near-tip peers + healthy), up to ${MAX_WAIT_MIN}m..."
deadline=$(( $(date +%s) + MAX_WAIT_MIN*60 ))
while :; do
  is_safe && { log "SAFE WINDOW - stopping cleanly now"; break; }
  if [ "$(date +%s)" -ge "$deadline" ]; then
    log "no clean window within ${MAX_WAIT_MIN}m (still catching up / under-peered / mid-reorg)."
    log "NOT stopping - mining continues. Re-run later, or raise MAX_WAIT_MIN, or fix peers (scripts/find-peers.sh --add)."
    exit 2
  fi
  sleep 15
done

# wait-only: caller (e.g. make deploy) just wants to know we're at a safe moment.
if [ "$ACTION" = "wait" ]; then log "safe window reached (ACTION=wait) - caller may proceed with the swap."; exit 0; fi

log "docker compose stop -t 120 $SVC (graceful flush; matches stop_grace_period)..."
docker compose stop -t 120 "$SVC"
# Confirm the flush actually completed (the whole point).
if docker exec "$SVC" sh -c 'tail -5 /data/debug.log 2>/dev/null' 2>/dev/null | grep -q "Shutdown: done"; then
  log "clean stop CONFIRMED ('Shutdown: done' in debug.log) -> next boot should fast-restore (~30s)."
else
  log "WARN: did not see 'Shutdown: done' - flush may have been truncated; next boot could rebuild."
fi

if [ "$ACTION" = "restart" ]; then
  log "starting back up (same container; expect ~30s fast-restore since we stopped caught-up + clean)..."
  t0=$(date +%s); docker compose start "$SVC"
  for _ in $(seq 1 120); do
    "${CLI[@]}" getblockcount >/dev/null 2>&1 && { log "RPC up after $(( $(date +%s)-t0 ))s (if this is ~30s, fast-restore worked)"; break; }
    sleep 5
  done
fi
