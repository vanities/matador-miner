#!/usr/bin/env bash
# Isolated BTX solo-miner entrypoint.
# - Installs ONLY the GPG-signed btxchain/btx release (verified) — never btxprice.com.
# - Mines to a wallet whose keys live in your mounted ./btx-data (self-custody).
# - Hands off to the project's own GPU mining loop (generatetoaddress via CUDA).
set -euo pipefail

DATADIR=/data
RELEASE_TAG="${RELEASE_TAG:-v0.32.2}"
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
# How to obtain btxd/btx-cli:
#   source  (default) — run the 0.32.2 binaries COMPILED INTO this image from the
#                       pinned tag commit (see Dockerfile). No download, no GPG:
#                       the image build is the trust boundary.
#   release           — alt path: download + GPG-verify the signed precompiled
#                       release named by RELEASE_TAG (set RELEASE_TAG=v0.32.2).
BTX_INSTALL_MODE="${BTX_INSTALL_MODE:-source}"

log(){ printf '\n\033[1;36m[btx-miner]\033[0m %s\n' "$*"; }

mkdir -p "$DATADIR"

find_bin(){
  local n="$1" c
  for c in "$INSTALL_DIR/bin/$n" "$DATADIR/bin/$n"; do [ -x "$c" ] && { echo "$c"; return 0; }; done
  c="$(command -v "$n" 2>/dev/null || true)"; [ -n "$c" ] && { echo "$c"; return 0; }
  find "$DATADIR" /opt -maxdepth 6 -type f -name "$n" -perm -u+x 2>/dev/null | head -1
}

# 1-2) Resolve btxd/btx-cli for the selected install mode.
if [ "$BTX_INSTALL_MODE" = source ]; then
  # Binaries were compiled into the image at /opt/btx/bin (see Dockerfile).
  BTXD=/opt/btx/bin/btxd
  CLI=/opt/btx/bin/btx-cli
  [ -x "$BTXD" ] && [ -x "$CLI" ] \
    || { log "Compiled btxd/btx-cli missing from image — rebuild with 'make up'."; exit 1; }
  # A prior release-mode run may have left precompiled binaries in the mounted
  # volume; they would otherwise shadow these compiled ones (find_bin checks the
  # volume first). Drop ONLY that bin dir — the chain + wallet live elsewhere
  # under $DATADIR and are never touched.
  if [ -d "$INSTALL_DIR" ]; then
    log "Removing stale release binaries from volume ($INSTALL_DIR) — chain/wallet untouched."
    rm -rf "$INSTALL_DIR"
  fi
else
  # ----- legacy release path: download + GPG-verify the signed precompiled release -----
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
fi
log "btxd:    $BTXD ($BTX_INSTALL_MODE)"
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
# Fresh high-score, synced peers from the minebtx live list (2026-06-12), US-first
# for low ping (Adam is US/TN) + a couple synced EU for redundancy. Supplements the
# older seeds above, several of which had gone stale. Refresh from minebtx.com/peers.
addnode=216.243.220.55:19335
addnode=178.128.156.73:19335
addnode=46.101.240.240:19335
addnode=79.127.128.100:19335
# Verified-good additions (2026-06-13): each was connected + synced + full-relay at
# harvest time, from our own getpeerinfo plus an addrman onetry sweep (most reachable
# synced nodes were already seeded above; the BTX reachable-node pool is small).
# Refresh from `getpeerinfo` (filter /BTX:0.32.x/ + synced + relaytxes=true) when stale.
addnode=86.217.243.230:19335
addnode=88.147.5.121:19335
addnode=62.238.22.167:19335
addnode=1.156.5.90:19335
# Verified-good (2026-06-15): connected + synced within 2 of tip + full-relay at
# harvest time. Added after a post-restart stale-peer partition (the node sat at a
# doomed stale tip with near_tip_peers=0 while the canonical chain advanced); the
# other 5 currently-synced anchors were already seeded above.
addnode=43.167.159.17:19335
CONF
fi

# 0.32.11+ pins shielded assumeutxo snapshots; our fast-start snapshot (v0.32.2,
# height 123225) is unpinned, so loadtxoutset refuses it without this override. With
# prune=0 (archival) the node rebuilds the unshield-velocity state locally after the
# load, so forcing it is safe. Idempotent: existing datadirs pick it up on next restart.
grep -q '^allowunpinnedshieldedsnapshot=' "$DATADIR/btx.conf" 2>/dev/null \
  || echo 'allowunpinnedshieldedsnapshot=1' >> "$DATADIR/btx.conf"

# 5) Briefly start the daemon to create YOUR wallet + payout address, then stop
#    it — the mining loop supervises its own daemon.
log "Starting btxd to provision your self-custody wallet..."
"$BTXD" -datadir="$DATADIR" -daemon
# On a warm restart after an unclean container exit, BTX can spend several
# minutes rebuilding shielded-state indexes while RPC reports "Loading wallet…"
# (-28).  The old 3-minute wait made the wrapper give up even though btxd was
# healthy and still recovering.  Give it enough room to finish and then mine.
for _ in $(seq 1 "${BTX_RPC_STARTUP_ATTEMPTS:-300}"); do "$CLI" -datadir="$DATADIR" getblockchaininfo >/dev/null 2>&1 && break; sleep 2; done
"$CLI" -datadir="$DATADIR" getblockchaininfo >/dev/null 2>&1 \
  || { log "RPC didn't come up; see $DATADIR/debug.log"; exit 1; }
"$CLI" -datadir="$DATADIR" -named createwallet wallet_name="$WALLET" load_on_startup=true >/dev/null 2>&1 \
  || "$CLI" -datadir="$DATADIR" -named loadwallet filename="$WALLET" load_on_startup=true >/dev/null 2>&1 || true
ADDR="$("$CLI" -datadir="$DATADIR" -rpcwallet="$WALLET" getnewaddress)"
echo "$ADDR" > "$DATADIR/miner-address.txt"
log "Mining rewards go to YOUR address: $ADDR"
log "Wallet keys live in ./btx-data on the host — back it up; nobody else holds them."

# 5b) Fast-start: load the assumeutxo snapshot (height ~123,225) to skip the
#     multi-hour genesis sync. Non-fatal — falls back to normal sync on failure.
#     SHA + height track the v0.32.2 release snapshot; the 0.32.2 binary's baked-in
#     assumeutxo hash matches THIS height, so older snapshots would be rejected.
SNAP_SHA="0ecc70ad6b38dc6469955b754abd255e69c6c97b78d5152e71d3c04167dec63c"
if [ "${BTX_USE_SNAPSHOT:-1}" = "1" ] && [ ! -f "$DATADIR/.snapshot_loaded" ]; then
  log "Fast-start: downloading assumeutxo snapshot (~440MB, height 123225)..."
  if curl -fsSL -o "$DATADIR/snapshot.dat" "https://github.com/btxchain/btx/releases/download/${RELEASE_TAG}/snapshot.dat" \
     && echo "$SNAP_SHA  $DATADIR/snapshot.dat" | sha256sum -c -; then
    # loadtxoutset rejects the snapshot unless the base block header is already
    # in the headers chain — so wait for headers to reach the snapshot height.
    log "Waiting for headers to reach the snapshot height (123225) before loadtxoutset..."
    for _ in $(seq 1 150); do
      hdrs=$("$CLI" -datadir="$DATADIR" getblockchaininfo 2>/dev/null | grep '"headers"' | tr -dc '0-9' || true)
      [ -n "${hdrs:-}" ] && [ "${hdrs}" -ge 123225 ] 2>/dev/null && { log "headers synced ($hdrs)"; break; }
      sleep 3
    done
    log "Loading snapshot via loadtxoutset (jumps to ~123,225; takes a few minutes)..."
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

# 5d) NODE-ONLY mode (BTX_MINING_ENABLED=0): keep the provisioning btxd up to
#     serve the wallet + RPC (make balance / stats / address) WITHOUT mining or
#     touching the GPU, so it can run alongside the pool (which owns the GPU).
#     The provisioning daemon started above is already up with the wallet loaded;
#     just supervise it here and flush cleanly on SIGTERM. No mining loop, no
#     generatetoaddress, so the card stays 100% available to btx-pool.
if [ "${BTX_MINING_ENABLED:-1}" = "0" ]; then
  node_only_stop() {
    log "[node] shutdown signal — flushing btxd cleanly..."
    "$CLI" -datadir="$DATADIR" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 115); do "$CLI" -datadir="$DATADIR" getblockcount >/dev/null 2>&1 || break; sleep 1; done
    log "[node] btxd stopped cleanly."
    exit 0
  }
  trap node_only_stop TERM INT
  log "[node] NODE-ONLY mode: btxd stays up for wallet/RPC (make balance / stats / address). No mining, no GPU."
  # Supervise: keep PID 1 alive while btxd answers RPC; short poll so a SIGTERM
  # lands promptly (the trap fires between sleeps, not after a long blocking wait).
  while "$CLI" -datadir="$DATADIR" getblockcount >/dev/null 2>&1; do sleep 15; done
  log "[node] btxd stopped responding unexpectedly; exiting for restart."
  exit 1
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
# Idle gate: pause GPU mining WITHOUT restarting btxd (no shielded-state warmup).
#   Stop the miner:  docker compose exec btx-miner touch /data/.pause-mining   (or: make stop-miner)
#   Resume:          docker compose exec btx-miner rm   /data/.pause-mining    (or: make start-miner)
# NOTE: keep these comments ABOVE the command. A comment line wedged between
# backslash line-continuations merges into the previous line, so its `#` would
# comment out every following arg (e.g. --should-mine-command) AND the trailing
# `&` — silently disabling the idle gate and breaking LOOP_PID/clean shutdown.
"$SRC/contrib/mining/live-mining-loop.sh" \
  --datadir="$DATADIR" \
  --wallet="$WALLET" \
  --address-file="$DATADIR/miner-address.txt" \
  --results-dir="$DATADIR/mining-ops" \
  --daemon="$BTXD" \
  --cli="$CLI" \
  --should-mine-command="test ! -f $DATADIR/.pause-mining" &
LOOP_PID=$!
wait "$LOOP_PID"
