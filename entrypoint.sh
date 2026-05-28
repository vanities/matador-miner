#!/usr/bin/env bash
# Isolated BTX solo-miner entrypoint.
# - Installs ONLY the GPG-signed btxchain/btx release (verified) — never btxprice.com.
# - Mines to a wallet whose keys live in your mounted ./btx-data (self-custody).
# - Hands off to the project's own GPU mining loop (generatetoaddress via CUDA).
set -euo pipefail

DATADIR=/data
RELEASE_TAG="${RELEASE_TAG:-v0.30.1}"
PLATFORM="${BTX_PLATFORM:-linux-x86_64-cuda13}"
INSTALL_DIR="$DATADIR/btx-bin"
SRC=/opt/btx-src
WALLET=miner
# Release signing key. NOTE: this key is published WITH the release and was
# created 2026-05-19, so verifying against it proves download INTEGRITY only,
# not authenticity (nobody independent vouches for it; the repo's SECURITY.md
# lists an unrelated Bitcoin dev's key). Acceptable ONLY because we run
# sandboxed with no funds — do not extend trust beyond this container.
EXPECTED_FPR="A8E17EF93249FCC3B8ACCF3D3A0454E5A6A8DC45"
export BTX_MATMUL_BACKEND="${BTX_MATMUL_BACKEND:-cuda}"

log(){ printf '\n\033[1;36m[btx-miner]\033[0m %s\n' "$*"; }

mkdir -p "$DATADIR"

find_bin(){
  local n="$1" c
  for c in "$INSTALL_DIR/bin/$n" "$DATADIR/bin/$n"; do [ -x "$c" ] && { echo "$c"; return 0; }; done
  c="$(command -v "$n" 2>/dev/null || true)"; [ -n "$c" ] && { echo "$c"; return 0; }
  find "$DATADIR" /opt -maxdepth 6 -type f -name "$n" -perm -u+x 2>/dev/null | head -1
}

# 1) Import the release signing key so the installer's GPG verification passes.
if ! gpg --list-keys "$EXPECTED_FPR" >/dev/null 2>&1; then
  log "Importing BTX release signing key $EXPECTED_FPR (integrity check only)..."
  curl -fsSL "https://github.com/btxchain/btx/releases/download/${RELEASE_TAG}/BTX-RELEASE-PUBKEY.asc" -o /tmp/btx-pubkey.asc
  gpg --import /tmp/btx-pubkey.asc
  gpg --list-keys "$EXPECTED_FPR" >/dev/null 2>&1 \
    || { log "Imported key != expected fingerprint — aborting."; exit 1; }
fi

# 2) Install (verify + extract) the signed CUDA-13 release. No bootstrap/daemon here.
if [ -z "$(find_bin btxd)" ]; then
  log "Installing signed BTX $RELEASE_TAG ($PLATFORM) from github.com/btxchain/btx ..."
  python3 "$SRC/contrib/faststart/btx-agent-setup.py" \
      --repo btxchain/btx --release-tag "$RELEASE_TAG" \
      --platform "$PLATFORM" --install-dir "$INSTALL_DIR" --force \
    || { log "Installer failed — see the manual steps in README.md"; exit 1; }
fi
BTXD="$(find_bin btxd)"; CLI="$(find_bin btx-cli)"
[ -n "$BTXD" ] && [ -n "$CLI" ] || { log "btxd/btx-cli not found after install."; exit 1; }
# Guard against a warm `docker restart`: find_bin can return the /usr/local/bin
# symlink itself, and re-linking it would point it at itself (ELOOP). Skip if so.
[ "$BTXD" = /usr/local/bin/btxd ]    || ln -sf "$BTXD" /usr/local/bin/btxd 2>/dev/null || true
[ "$CLI"  = /usr/local/bin/btx-cli ] || ln -sf "$CLI"  /usr/local/bin/btx-cli 2>/dev/null || true
log "btxd:    $BTXD"
log "btx-cli: $CLI"

# 3) Confirm the CUDA MatMul backend is runtime-ready on this GPU.
INFO="$(find_bin btx-matmul-backend-info || true)"
[ -n "$INFO" ] && { log "CUDA backend check:"; "$INFO" --backend cuda || log "WARNING: CUDA backend not ready (host driver / nvidia-container-toolkit?)."; }

# 4) Minimal mainnet config: cookie auth + peer discovery + seed nodes.
if [ ! -f "$DATADIR/btx.conf" ]; then
  cat > "$DATADIR/btx.conf" <<CONF
server=1
listen=1
# Archival (prune=0): keep all blocks so RebuildShieldedState can never fail on a
# pruned node — this is what caused the recurring shielded-state crash. ~119GB + ~1GB/day.
prune=0
dbcache=2048
dnsseed=1
fixedseeds=1
# Looser chain_guard: fewer mining-pause flaps on the sparse network (small orphan-risk tradeoff).
miningchainguardminpeers=1
miningchainguardmaxmediangap=12
miningminsyncedoutboundpeers=1
addnode=node.btx.tools:19335
addnode=146.190.179.86:19335
addnode=164.90.246.229:19335
addnode=38.224.253.68:19335
addnode=167.172.147.186:19335
addnode=167.71.191.49:19335
addnode=5.78.219.123:19335
addnode=206.189.253.106:19335
addnode=143.198.155.4:19335
addnode=24.199.117.29:19335
addnode=5.78.69.145:19335
addnode=3.26.207.104:19335
addnode=143.110.151.57:19335
addnode=134.209.226.24:19335
addnode=54.206.106.238:19335
addnode=3.26.17.239:19335
addnode=42.3.112.136:19335
addnode=86.96.19.11:19335
addnode=101.166.40.122:19335
addnode=101.190.74.74:19335
addnode=101.190.6.79:19335
addnode=1.156.47.118:19335
addnode=124.168.58.173:19335
CONF
fi

# 5) Briefly start the daemon to create YOUR wallet + payout address, then stop
#    it — the mining loop supervises its own daemon.
log "Starting btxd to provision your self-custody wallet..."
"$BTXD" -datadir="$DATADIR" -daemon
for _ in $(seq 1 90); do "$CLI" -datadir="$DATADIR" getblockchaininfo >/dev/null 2>&1 && break; sleep 2; done
"$CLI" -datadir="$DATADIR" getblockchaininfo >/dev/null 2>&1 \
  || { log "RPC didn't come up; see $DATADIR/debug.log"; exit 1; }
"$CLI" -datadir="$DATADIR" -named createwallet wallet_name="$WALLET" load_on_startup=true >/dev/null 2>&1 \
  || "$CLI" -datadir="$DATADIR" -named loadwallet filename="$WALLET" load_on_startup=true >/dev/null 2>&1 || true
ADDR="$("$CLI" -datadir="$DATADIR" -rpcwallet="$WALLET" getnewaddress)"
echo "$ADDR" > "$DATADIR/miner-address.txt"
log "Mining rewards go to YOUR address: $ADDR"
log "Wallet keys live in ./btx-data on the host — back it up; nobody else holds them."

# 5b) Fast-start: load the assumeutxo snapshot (height ~106,875) to skip the
#     multi-hour genesis sync. Non-fatal — falls back to normal sync on failure.
SNAP_SHA="d4026096c04e3ce82342d3bb40695d84c70b0a9996cfeaaf95fbbb547a0520c0"
if [ "${BTX_USE_SNAPSHOT:-1}" = "1" ] && [ ! -f "$DATADIR/.snapshot_loaded" ]; then
  log "Fast-start: downloading assumeutxo snapshot (~347MB, height 106875)..."
  if curl -fsSL -o "$DATADIR/snapshot.dat" "https://github.com/btxchain/btx/releases/download/${RELEASE_TAG}/snapshot.dat" \
     && echo "$SNAP_SHA  $DATADIR/snapshot.dat" | sha256sum -c -; then
    # loadtxoutset rejects the snapshot unless the base block header is already
    # in the headers chain — so wait for headers to reach the snapshot height.
    log "Waiting for headers to reach the snapshot height (106875) before loadtxoutset..."
    for _ in $(seq 1 150); do
      hdrs=$("$CLI" -datadir="$DATADIR" getblockchaininfo 2>/dev/null | grep '"headers"' | tr -dc '0-9' || true)
      [ -n "${hdrs:-}" ] && [ "${hdrs}" -ge 106875 ] 2>/dev/null && { log "headers synced ($hdrs)"; break; }
      sleep 3
    done
    log "Loading snapshot via loadtxoutset (jumps to ~106,875; takes a few minutes)..."
    if "$CLI" -datadir="$DATADIR" -rpcclienttimeout=0 loadtxoutset "$DATADIR/snapshot.dat"; then
      touch "$DATADIR/.snapshot_loaded"; rm -f "$DATADIR/snapshot.dat"
      log "Snapshot loaded — node is near tip."
    else
      log "WARNING: loadtxoutset rejected (binary assumeutxo mismatch?) — falling back to full sync."
    fi
  else
    log "WARNING: snapshot download/checksum failed — falling back to full sync."
  fi
fi

log "Stopping provisioning daemon; mining loop takes over next..."
"$CLI" -datadir="$DATADIR" stop >/dev/null 2>&1 || true
for _ in $(seq 1 30); do "$CLI" -datadir="$DATADIR" getblockchaininfo >/dev/null 2>&1 || break; sleep 1; done

# 6) Hand off to the project's GPU mining supervisor. Run it in the background
#    and trap SIGTERM/SIGINT so we shut btxd down GRACEFULLY (flush chainstate +
#    shielded state) instead of letting Docker hard-kill it. A hard kill
#    mid-write corrupts the shielded DB, which a pruned node can't rebuild.
#    Pair this with `stop_grace_period` in docker-compose.yml so Docker waits.
graceful_stop() {
  log "Shutdown signal — stopping mining loop and flushing btxd cleanly..."
  [ -n "${LOOP_PID:-}" ] && kill "$LOOP_PID" 2>/dev/null || true
  "$CLI" -datadir="$DATADIR" stop >/dev/null 2>&1 || true
  for _ in $(seq 1 115); do "$CLI" -datadir="$DATADIR" getblockcount >/dev/null 2>&1 || break; sleep 1; done
  log "btxd stopped cleanly."
  exit 0
}
trap graceful_stop TERM INT

log "Starting GPU mining loop (generatetoaddress via CUDA). 'docker compose down' stops cleanly now."
"$SRC/contrib/mining/live-mining-loop.sh" \
  --datadir="$DATADIR" \
  --wallet="$WALLET" \
  --address-file="$DATADIR/miner-address.txt" \
  --results-dir="$DATADIR/mining-ops" \
  --daemon="$BTXD" \
  --cli="$CLI" \
  --should-mine-command=/bin/true &
LOOP_PID=$!
wait "$LOOP_PID"
