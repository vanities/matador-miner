#!/usr/bin/env bash
# mining-watchdog.sh - solo mining health watchdog + auto-recovery (idea #2,
# folding in #4 peer-monitor and #5 pause-state-monitor).
#
# Samples liveness every INTERVAL: container state, solve counter (the direct
# "is the GPU finding nonces" signal), tip height, near_tip_peers, should_pause,
# GPU util, and the empty-block keeper. Detects a STALL = at tip + mining NOT
# paused + solve counter flat for STALL_MIN minutes (the exact signature of the
# v3 freeze). On a stall it ALERTs and auto-restarts the miner, but if a restart
# does NOT clear it (e.g. a consensus/version stall, which a restart cannot fix)
# it escalates to CRITICAL and stops restart-looping - so a human gets pinged
# fast instead of the rig silently idling for hours.
#
# Run on pc, detached:
#   cd ~/git/btx-miner && mkdir -p ops-logs
#   nohup bash scripts/mining-watchdog.sh >> ops-logs/mining-watchdog.log 2>&1 </dev/null & disown
# Optional push alerts: set ALERT_CMD to a command that reads the message on stdin
#   ALERT_CMD='curl -s -d @- ntfy.sh/my-btx-rig' nohup bash scripts/mining-watchdog.sh ...
# Stop it:  pkill -f mining-watchdog.sh   (run from a dir whose path lacks that string)
set -uo pipefail

INTERVAL="${INTERVAL:-60}"            # sample period (s)
STALL_MIN="${STALL_MIN:-5}"          # solve counter flat this many minutes => stall
PEER_MIN="${PEER_MIN:-10}"           # near_tip_peers==0 this many minutes => peering warning
MAX_RESTARTS="${MAX_RESTARTS:-2}"    # auto-restarts per stall episode before escalating to CRITICAL
ALERT_CMD="${ALERT_CMD:-}"           # optional push command; receives the alert text on stdin
SVC="${SVC:-btx-miner}"
ALERT_FILE="${ALERT_FILE:-ops-logs/ALERT.txt}"

CLI=(docker compose exec -T "$SVC" btx-cli -datadir=/data)
log() { echo "[$(date +%FT%T)] [watchdog] $*"; }
alert() { # $1=level $2=msg
  log "$1: $2"
  echo "[$(date +%FT%T)] $1: $2" >> "$ALERT_FILE" 2>/dev/null || true
  [ -n "$ALERT_CMD" ] && printf '%s\n' "[$SVC] $1: $2" | timeout 20 bash -c "$ALERT_CMD" >/dev/null 2>&1 || true
}
solvecnt() { "${CLI[@]}" getmatmulchallengeprofile 2>/dev/null | jq -r '.service_profile.runtime_observability.solve_pipeline.batched_nonce_attempts // 0' | tr -dc 0-9; }

stall_need=$(( STALL_MIN*60 / INTERVAL )); [ "$stall_need" -lt 1 ] && stall_need=1
peer_need=$(( PEER_MIN*60 / INTERVAL )); [ "$peer_need" -lt 1 ] && peer_need=1
stall_samples=0; peer_zero=0; restarts=0; cyc=0
prev_solve="$(solvecnt)"; prev_solve="${prev_solve:-0}"
log "start: interval=${INTERVAL}s stall>=${STALL_MIN}m(${stall_need} samples) peer0>=${PEER_MIN}m max_restarts=$MAX_RESTARTS/episode svc=$SVC"

while :; do
  cyc=$((cyc+1)); sleep "$INTERVAL"

  # --- container alive? ---
  cstate="$(docker inspect -f '{{.State.Status}}' "$SVC" 2>/dev/null || echo missing)"
  if [ "$cstate" != "running" ]; then
    alert "ALERT" "container $SVC is '$cstate' (not running)"
    if [ "$restarts" -lt "$MAX_RESTARTS" ]; then
      restarts=$((restarts+1)); log "recover $restarts/$MAX_RESTARTS: docker compose up -d $SVC"
      docker compose up -d "$SVC" >/dev/null 2>&1
    else alert "CRITICAL" "$SVC down and restart budget spent ($restarts) - needs a human"; fi
    continue
  fi

  # --- chain + mining snapshot ---
  bi="$("${CLI[@]}" getblockchaininfo 2>/dev/null)"
  H="$(echo "$bi"  | jq -r '.blocks // 0' 2>/dev/null)";  H="${H:-0}"
  HD="$(echo "$bi" | jq -r '.headers // 0' 2>/dev/null)"; HD="${HD:-0}"
  IBD="$(echo "$bi"| jq -r '.initialblockdownload // false' 2>/dev/null)"
  mi="$("${CLI[@]}" getmininginfo 2>/dev/null)"
  # select(has(...)) finds the value even when it is a genuine 0/false; NO jq `//` (it would
  # replace a real false/0 with the fallback), so default in bash instead.
  ntp="$(echo "$mi" | jq -r 'first(.. | objects | select(has("near_tip_peers")) | .near_tip_peers)' 2>/dev/null | tr -dc 0-9)"; ntp="${ntp:-0}"
  paused="$(echo "$mi" | jq -r 'first(.. | objects | select(has("should_pause_mining")) | .should_pause_mining)' 2>/dev/null)"; paused="${paused:-false}"
  gpu="$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -dc 0-9)"; gpu="${gpu:-0}"
  cur_solve="$(solvecnt)"; cur_solve="${cur_solve:-0}"
  d=$(( cur_solve - prev_solve )); prev_solve="$cur_solve"

  # Idle gate: if the miner is DELIBERATELY paused (make stop-miner / make pool /
  # make matador all set /data/.pause-mining), the solve counter is flat ON PURPOSE.
  # The watchdog must NOT read that as a stall and restart - that fights the idle
  # gate and triggers a needless shielded-state rebuild warmup. (Bug hit live
  # 2026-06-15: the watchdog restarted idle-gated solo during a pool test.)
  idle_gated=no
  docker exec "$SVC" test -f /data/.pause-mining 2>/dev/null && idle_gated=yes

  # --- idle-gate short-circuit: leave a DELIBERATELY-paused miner alone ---
  if [ "$idle_gated" = "yes" ]; then
    stall_samples=0; peer_zero=0   # flat counter + stale peers are expected while paused
    [ $((cyc % 10)) -eq 0 ] && log "idle-gated (.pause-mining set): mining paused on purpose, skipping stall/peer recovery (h=$H gpu=${gpu}%)"
  else

  # --- peering monitor + auto-remediation (idea #4) ---
  # A uniformly-STALE peer set is the dangerous case: every connected peer agrees
  # on an old tip, so chain-guard sees no median gap (should_pause stays false) and
  # the miner happily mines a DOOMED tip. near_tip_peers=0 at tip is the tell.
  # Confirmed live 2026-06-15 (post-restart partition at h=131559 while canonical
  # was 131613); `find-peers.sh --add` fixed it instantly. So here we don't just
  # warn — we auto-run it (once per episode; peer_zero resets when peers recover).
  if [ "$IBD" != "true" ] && [ "$ntp" -le 0 ] 2>/dev/null; then
    peer_zero=$((peer_zero+1))
    if [ "$peer_zero" -eq "$peer_need" ]; then
      alert "WARN" "near_tip_peers=0 for ${PEER_MIN}m at tip - stale-tip risk high under v3; auto-running find-peers --add"
      if [ -f scripts/find-peers.sh ]; then
        timeout 150 bash scripts/find-peers.sh --add >/dev/null 2>&1 \
          && log "auto-remediation: find-peers --add completed" \
          || log "auto-remediation: find-peers --add failed/timed out"
      else
        log "auto-remediation skipped: scripts/find-peers.sh not found (run watchdog from the repo dir)"
      fi
    fi
  else peer_zero=0; fi

  # --- stall detection: node UP + at tip, NOT paused, but solve counter flat ---
  # REQUIRE H>0 (RPC responding): during a warmup btxd's RPC is down (-28) so a
  # flat counter is NOT a stall - restarting then would just relaunch the warmup
  # (a warmup loop). A truly-dead container is caught by the container-status check
  # above; an up-but-warming node must be left to finish.
  if [ "$H" -gt 0 ] 2>/dev/null && [ "$IBD" != "true" ] && [ "$paused" = "false" ] && [ "$d" -le 0 ] 2>/dev/null; then
    stall_samples=$((stall_samples+1))
    if [ "$stall_samples" -ge "$stall_need" ]; then
      alert "ALERT" "STALL: solve counter flat ${STALL_MIN}m (delta=$d, gpu=${gpu}%) at h=$H/$HD, mining not paused"
      if [ "$restarts" -lt "$MAX_RESTARTS" ]; then
        restarts=$((restarts+1)); log "recover $restarts/$MAX_RESTARTS: clean restart $SVC (stop -t 120 lets btxd FLUSH; a kill -9 mid-write leaves stale LOCKs + forces a full shielded rebuild)"
        # CLEAN restart per shib: never SIGKILL btxd. `restart` defaults to a 10s
        # timeout (SIGKILL after 10s) which truncates the shielded-state flush ->
        # stale blocks/.lock + leveldb/shielded_state LOCK + a from-genesis rebuild
        # next boot. -t 120 matches stop_grace_period so graceful_stop can finish.
        docker compose restart -t 120 "$SVC" >/dev/null 2>&1
        stall_samples=0; prev_solve="$(solvecnt)"
      else
        alert "CRITICAL" "STALL persists after $restarts restarts - likely consensus/version (the v3 freeze needed 0.32.11, not a restart). Auto-restart OFF; needs a human."
        stall_samples=0
      fi
    fi
  else
    stall_samples=0
    [ "$d" -gt 0 ] 2>/dev/null && restarts=0   # healthy progress resets the restart budget
  fi

  fi  # end idle-gate short-circuit

  # --- heartbeat (every ~10 samples) ---
  if [ $((cyc % 10)) -eq 0 ]; then
    kalive="$(pgrep -f empty-block-keeper.sh >/dev/null 2>&1 && echo yes || echo NO)"
    [ "$kalive" = "NO" ] && [ "$H" -lt 132000 ] 2>/dev/null && alert "WARN" "empty-block keeper not running while still in penalty window (h=$H<132000)"
    # btxd continuous uptime = node trust / propagation "social credit" (resets on restart).
    up="$("${CLI[@]}" uptime 2>/dev/null | tr -dc 0-9)"; up="${up:-0}"
    log "ok h=$H/$HD ibd=$IBD paused=$paused idle_gated=$idle_gated solve+=$d gpu=${gpu}% near_tip_peers=$ntp keeper=$kalive uptime=$((up/3600))h$(((up%3600)/60))m restarts=$restarts"
  fi
done
