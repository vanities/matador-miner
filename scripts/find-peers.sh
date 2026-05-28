#!/usr/bin/env bash
# Discover good BTX peers from the running node's address book and (optionally)
# whitelist the reachable ones as sticky addnodes (live + btx.conf).
#
#   bash scripts/find-peers.sh           # discover + reachability test (dry run)
#   bash scripts/find-peers.sh --geo     # + annotate survivors via ipinfo.io
#   bash scripts/find-peers.sh --add     # + addnode the reachable ones (live + persisted)
#
# Why: addnode entries are sticky (btxd retries them forever); auto-discovered
# peers are forgotten on disconnect, which is what makes a sparse network flaky.
# reset-faststart wipes peers.dat, so re-run this after a reset to repopulate.
#
# Run on the GPU host (needs docker + the running btx-miner container, plus
# host-side jq/curl/bash for the connect test).
set -uo pipefail

CT="${CT:-btx-miner}"
PORT="${PORT:-19335}"
TEST_N="${TEST_N:-80}"   # probe this many freshest candidates
ADD=0; GEO=0
for a in "$@"; do case "$a" in --add) ADD=1 ;; --geo) GEO=1 ;; esac; done

dx()  { docker exec "$CT" "$@"; }
cli() { dx btx-cli -datadir=/data "$@"; }

docker ps --filter "name=^/${CT}$" --filter status=running -q | grep -q . \
  || { echo "container '$CT' is not running"; exit 1; }

echo "==> dumping address book (getnodeaddresses)..."
cli getnodeaddresses 0 > /tmp/btx-addrs.json 2>/dev/null
tot=$(jq length /tmp/btx-addrs.json 2>/dev/null || echo 0)
CANDS=$(jq -r --argjson p "$PORT" \
  '[.[]|select(.port==$p and .network=="ipv4" and (now-.time)<604800)]|sort_by(-.time)|.[].address' \
  /tmp/btx-addrs.json 2>/dev/null | head -"$TEST_N")
n=$(printf '%s\n' "$CANDS" | grep -c . || true)
echo "    book=$tot  fresh ipv4 :$PORT probed=$n"

echo "==> reachability test (TCP connect :$PORT, 3s, parallel)..."
GOOD=$(for ip in $CANDS; do ( timeout 3 bash -c "exec 3<>/dev/tcp/$ip/$PORT" 2>/dev/null && echo "$ip" ) & done; wait)
ng=$(printf '%s\n' "$GOOD" | grep -c . || true)
echo "    reachable (accept inbound)=$ng"

for ip in $GOOD; do
  if [ "$GEO" = 1 ]; then
    g=$(curl -s --max-time 4 "https://ipinfo.io/$ip/json" \
        | jq -r '[.city,.region,.country,.org]|map(select(.!=null and .!=""))|join(", ")' 2>/dev/null)
    echo "  $ip   ${g:-<geo n/a>}"
  else
    echo "  $ip"
  fi
done

if [ "$ADD" != 1 ]; then
  echo "(dry run — re-run with --add to whitelist these)"
  exit 0
fi

echo "==> whitelisting reachable peers (live addnode + append to btx.conf)..."
for ip in $GOOD; do
  cli addnode "$ip:$PORT" add >/dev/null 2>&1 || true
  dx sh -c "grep -q \"addnode=$ip:\" /data/btx.conf || echo \"addnode=$ip:$PORT\" >> /data/btx.conf"
done
echo "    btx.conf now has $(dx sh -c 'grep -c ^addnode= /data/btx.conf') addnodes"
echo "    (persisted; also seed scripts/../entrypoint.sh for fresh-data-dir starts)"
