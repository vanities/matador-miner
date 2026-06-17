#!/usr/bin/env bash
# matador-coordinator.sh - one command to bring up the fleet coordinator: the GBT proxy
# (workers solo-mine through it) + the telemetry hub (dashboard). See docs/matador-fleet.md.
#
# Env:
#   FLEET_TOKEN       (required) shared token workers present as their RPC password
#   NODE_URL          btxd JSON-RPC URL                  (default http://127.0.0.1:19334/)
#   NODE_COOKIE       btxd .cookie path                  (default ~/.btx/.cookie)
#   NODE_RPCUSER / NODE_RPCPASSWORD  use instead of the cookie
#   HUB_WORKERS       "label=url,label2=url2" rigs to scrape   (or use HUB_CONFIG)
#   HUB_CONFIG        path to hub.json with a workers[] array
# Flags:
#   --listen <addr>   bind BOTH services to this addr (default 127.0.0.1; use your VPN IP)
#   --proxy-port N    default 4071        --hub-port N   default 4070
#
# Bind to a VPN/LAN IP and firewall it; the token is the only gate. Run under systemd for
# production (Restart=always) - this script exits if either child dies so systemd recovers.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LISTEN=127.0.0.1; PROXY_PORT=4071; HUB_PORT=4070
while [ $# -gt 0 ]; do case "$1" in
  --listen) LISTEN=$2; shift 2;;
  --proxy-port) PROXY_PORT=$2; shift 2;;
  --hub-port) HUB_PORT=$2; shift 2;;
  *) echo "unknown arg: $1"; exit 2;;
esac; done

: "${FLEET_TOKEN:?set FLEET_TOKEN (the shared worker password)}"
NODE_URL="${NODE_URL:-http://127.0.0.1:19334/}"

proxy_auth=()
if [ -n "${NODE_RPCUSER:-}" ]; then
  proxy_auth=(--node-rpcuser "$NODE_RPCUSER" --node-rpcpassword "${NODE_RPCPASSWORD:-}")
else
  proxy_auth=(--node-cookie "${NODE_COOKIE:-$HOME/.btx/.cookie}")
fi

hub_args=()
if [ -n "${HUB_CONFIG:-}" ]; then
  hub_args=(--config "$HUB_CONFIG")
elif [ -n "${HUB_WORKERS:-}" ]; then
  IFS=',' read -ra ws <<< "$HUB_WORKERS"
  for w in "${ws[@]}"; do hub_args+=(--worker "$w"); done
else
  echo "set HUB_WORKERS (\"label=url,...\") or HUB_CONFIG"; exit 2
fi

PIDS=()
trap 'echo "[coordinator] stopping"; for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done' EXIT INT TERM

echo "[coordinator] proxy :$PROXY_PORT -> $NODE_URL  |  hub :$HUB_PORT  |  listen $LISTEN"
python3 "$HERE/matador-gbt-proxy.py" --listen "$LISTEN" --port "$PROXY_PORT" \
  --node-url "$NODE_URL" "${proxy_auth[@]}" --token "$FLEET_TOKEN" & PIDS+=($!)
python3 "$HERE/matador-hub.py" --listen "$LISTEN" --port "$HUB_PORT" "${hub_args[@]}" & PIDS+=($!)

echo "[coordinator] up. dashboard: http://$LISTEN:$HUB_PORT   workers point at --rpcport $PROXY_PORT"
# Exit (cleaning up the survivor via the trap) if EITHER child dies, so a supervisor restarts us.
wait -n
echo "[coordinator] a child exited; shutting down the other"
