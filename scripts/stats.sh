#!/usr/bin/env bash
# One-shot BTX miner dashboard. Works from ANY directory.
#   bash scripts/stats.sh        (or:  make stats)
set -uo pipefail
SVC="${SVC:-btx-miner}"
WALLET="${WALLET:-miner}"

cyan(){ printf '\033[1;36m%s\033[0m\n' "$*"; }

cyan "── BTX MINER ──  $(date '+%Y-%m-%d %H:%M:%S')"
# Detect by container name (CWD-independent) rather than `docker compose ps`.
status=$(docker ps --filter "name=$SVC" --format '{{.Status}}' 2>/dev/null | head -1)
printf 'container : %s\n' "${status:-NOT RUNNING (no container named '$SVC')}"

if [ -n "${status:-}" ]; then
  docker exec -i "$SVC" sh 2>/dev/null <<EOF
q() { btx-cli -datadir=/data "\$@"; }
q -rpcwallet=$WALLET getwalletinfo 2>/dev/null | jq -r '"balance   : \(.balance) + \(.immature_balance) immature = \(.balance + .immature_balance) BTX   (\(.txcount) txns)"'
q getblockchaininfo 2>/dev/null | jq -r '"height    : \(.blocks) / \(.headers)   IBD=\(.initialblockdownload)"'
q getmininginfo 2>/dev/null | jq -r '"difficulty: \(.difficulty)\nnet h/s   : \(.networkhashps|floor)\nmining    : paused=\(.chain_guard.should_pause_mining)  \(.chain_guard.reason)  peers=\(.chain_guard.peer_count)  near_tip=\(.chain_guard.near_tip_peers)"'
EOF
fi

if [ -n "${status:-}" ]; then
  cyan "REWARDS"
  # Win rate from the wallet's coinbase txns. Quoted heredoc (<<'SH') so jq's
  # $r/$n/now/\(...) pass through untouched; WALLET goes in via -e and is
  # expanded by the container shell, not the outer one.
  docker exec -i -e WALLET="$WALLET" "$SVC" sh 2>/dev/null <<'SH'
btx-cli -datadir=/data -rpcwallet="$WALLET" listtransactions '*' 100000 0 2>/dev/null | jq -r '
[.[] | select(.category=="generate" or .category=="immature")] as $r
| ([.[] | select(.category=="orphan")] | length) as $orph
| ($r | map(.blocktime) | sort) as $t
| ($t | length) as $n
| now as $N
| if $n == 0 then "won       : none yet (\($orph) orphaned)"
  else
    ($t[0]) as $f | ($t[-1]) as $l | (($l-$f)/86400) as $sp | (if $sp<1 then 1 else $sp end) as $spd
    | ((($N-$f)/604800)|ceil) as $wk
    | (($f/86400)|floor) as $D0 | (($N/86400)|floor) as $D1 | (if $D1-29>$D0 then $D1-29 else $D0 end) as $S
    | ([range($S; $D1+1)] | map(. as $dd | ([$t[]|select(.>=($dd*86400) and .<(($dd+1)*86400))]|length))) as $cc
    | ($cc|max) as $mx
    | "won       : \($n) blocks  ·  \((($r|map(.amount)|add)*100|floor)/100) BTX  ·  \($orph) orphaned",
      "win rate  : \((($n/$spd)*100|floor)/100)/day  \((($n/$spd*7)*10|floor)/10)/week lifetime  ·  7d=\($r|map(select(.blocktime>($N-604800)))|length)  24h=\($r|map(select(.blocktime>($N-86400)))|length)",
      "by week   : " + ([range(0; (if $wk>6 then 6 else $wk end))] | map(. as $k | ($N-($k*604800)) as $hi | ($N-(($k+1)*604800)) as $lo | ([$t[]|select(.>$lo and .<=$hi)]|length) as $c | (if $lo>$f then $lo else $f end) as $alo | (($hi-$alo)/86400) as $d | (if $k==0 then "this" else "\($k)w" end) as $lab | "\($lab) \($c)(\(if $d>0.1 then (($c/$d)*10|floor)/10 else 0 end)/d)") | join("  ·  ")) + (if $wk>6 then "  ·  +\($wk-6)w" else "" end),
      "trend     : " + ($cc|map((if $mx>0 then (./$mx*8)|round else 0 end)|[" ","▁","▂","▃","▄","▅","▆","▇","█"][.])|join("")) + "  blocks/day (\($cc|length)d)",
      "cadence   : ~\((($sp*24/(if $n>1 then $n-1 else 1 end))*10|floor)/10)h avg gap  ·  last \($l|todate) (\((((($N-$l)/3600)*10)|floor)/10)h ago)"
  end
'
SH
fi

cyan "GPU"
nvidia-smi --query-gpu=utilization.gpu,utilization.memory,clocks.current.sm,clocks.max.sm,power.draw,power.limit,temperature.gpu --format=csv,noheader 2>/dev/null \
  | awk -F', *' '{printf "util %s | mem %s | clk %s/%s | pwr %s/%s | %s\n",$1,$2,$3,$4,$5,$6,$7}'
printf 'nonce/s   : ~121K @460W (solve-bench reference; no live meter)\n'
