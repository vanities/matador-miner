# matador-miner - isolated GPU miner for `btxchain/btx`

![MATADOR - fearless BTX MatMul miner](docs/matador.png)

> **Solo mining** (`make solo`): a sandboxed BTX full node + CUDA MatMul miner pinned to
> **0.32.11**, keeping 100% of every block it finds (no fee) plus our +22.9%
> pipeline-overlap.

A Docker setup to point an idle NVIDIA GPU (e.g. an RTX 5090) at the `btxchain/btx` chain
and mine, keeping the node, miner, and wallet data isolated from the host.

> **Upstream / official node:** [`github.com/btxchain/btx`](https://github.com/btxchain/btx). Pinned to **v0.32.11** (commit [`215170f2`](https://github.com/btxchain/btx/commit/215170f27f7d6889ce34aa7dbba2858ea07a468c)). This repo **compiles that exact commit from source** with the CUDA MatMul backend by choice - it guarantees native `sm_120` codegen for the 5090 and a byte-reproducible build. To run the GPG-signed prebuilt instead, set `BTX_INSTALL_MODE=release` + `RELEASE_TAG=v0.32.11` in `docker-compose.yml`.
>
> **Consensus timeline (upgrade before each height or you fork off the network):** block **125,000** shielded sunset + MatMul nonce-seed **v2**; **130,000** temporary empty-block subsidy penalty; **130,500** MatMul seed-derivation **v3** (binds each nonce's seed to the parent block's `parent_mtp`); **132,000** forward consensus (shielded-exit velocity cap, empty-block penalty ends). 0.32.11 covers all of these.

## What this does

- Compiles `btxd` + `btx-cli` and the CUDA MatMul backend from a pinned upstream commit (**0.32.11**), in the Docker build.
- Runs that BTX full node in Docker (archival, `prune=0`, so shielded-state rebuilds never fail).
- Creates/uses a local wallet under `./btx-data`.
- Starts a supervised GPU **solo**-mining loop using BTX's MatMul proof-of-work.

## Safety model (why this is the contained way to try it)

- Runs entirely in a container; the node/miner cannot see your host filesystem.
- **Source build:** compiles a single, pinned, immutable commit (0.32.11) from
  [`github.com/btxchain/btx`](https://github.com/btxchain/btx). The signed
  release key is integrity-only (self-published, no independent vouching), so
  commit pinning is comparable trust - and a native `sm_120` compile is better
  for the 5090. Acceptable **only** because everything runs sandboxed here with
  no funds at stake; do not extend trust beyond this container. Set
  `BTX_INSTALL_MODE=release` to run the signed prebuilt instead.
- Mines to a wallet generated **inside your mounted `./btx-data`** so the wallet
  state and keys persist outside the container.
- Publishes no ports and does not require any external wallet service.

## Prerequisites (on the Linux box with the GPU)

- Docker + Docker Compose v2
- Recent NVIDIA driver (Blackwell RTX 5090 needs a current R570+/R580+ driver)
- `nvidia-container-toolkit` installed and configured:
  `sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker`
- Confirm the GPU is visible to Docker:
  `docker run --rm --gpus all nvidia/cuda:12.8.0-runtime-ubuntu24.04 nvidia-smi`

## Run

```bash
# copy this folder to the Linux box, then:
make solo        # build (first run) + solo-mine on 0.32.11
make help        # all targets: up/down/logs/status/balance/backup/restore/deploy/...
```

First build **compiles btxd + the CUDA backend from source** (a one-time
~20-40 min step; the NVIDIA CUDA toolchain it needs is pulled into the Docker
build, not your host). After that it syncs the chain (fast-start / assumeutxo
keeps this short - see [Fast-start](#fast-start--snapshot-0321), prints **your**
mining address, and starts a supervised solo-mining loop. Rebuilds reuse Docker's
layer cache, so nothing recompiles unless you change `BTX_SOURCE_REF`.

## Install the prebuilt miner (`matador-miner`)

Prefer a single binary over the Docker stack? `matador-miner` is a **standalone solo GPU
miner**: it pulls work from **your own `btxd`** via `getblocktemplate`, solves on the GPU
(our +22.9% overlap is baked in), and submits with `submitblock`. It is **decoupled from
the node**, so updating the miner never restarts `btxd` (no shielded-state warmup, no lost
propagation standing). Linux x86-64, NVIDIA Blackwell `sm_120` (RTX 5090).

**One-line install** (downloads the latest release, verifies the sha256, installs to
`/usr/local/bin`):

```bash
curl -fsSL https://raw.githubusercontent.com/vanities/matador-miner/main/install.sh | bash
```

Pin a version or change the install dir with env vars:
`VERSION=v0.1.0 PREFIX=$HOME/.local/bin` before the pipe. Prefer to inspect first? Read
[`install.sh`](install.sh), or do it by hand:

```bash
api=https://api.github.com/repos/vanities/matador-miner/releases/latest
url=$(curl -fsSL "$api" | grep -oE '"browser_download_url": *"[^"]+linux-x86_64"' | cut -d'"' -f4)
curl -fsSLO "$url" && curl -fsSLO "$url.sha256"          # binary + checksum
sha256sum -c "$(basename "$url").sha256"                 # must print: OK
chmod +x "$(basename "$url")" && sudo mv "$(basename "$url")" /usr/local/bin/matador-miner
matador-miner --help
```

**Run it** against a synced `btxd` (this repo's `make node`, or any `btxd` v0.32.11+ with
RPC enabled):

```bash
matador-miner \
  --chain main \
  --payoutaddress btx1...your-P2MR-address \   # getnewaddress from a current btx wallet
  --rpccookiefile ~/.btx/.cookie               # or --rpcuser/--rpcpassword
# extras: --rpcconnect 127.0.0.1 --rpcport 19334 --maxtries N
#         --dev-fee 1 (default; 0 disables)  --dev-address <addr>  LOG_LEVEL=debug
```

- **Solo + your keys only.** It submits to *your* `btxd` over **localhost RPC** and holds
  **no wallet keys**; mined coins pay the `--payoutaddress` you provide.
- **1% dev fee, time-based + transparent.** Like Claymore/PhoenixMiner/T-Rex, it points the
  coinbase at the dev address for ~1% of wall-clock time (~36s/hr) and **logs every
  entry/exit** of that window. Turn it off with `--dev-fee 0`.
- Closed-source binary (AM2 LLC); **verify the sha256** before running. `LOG_LEVEL=debug`
  for full per-stage solve timing, every template, every submit (accept/reject + reason).

## Why solo

You run your own node + our CUDA solver, keep 100% of every block (no fee), saturate the
GPU (~100% on a 5090), and get our +22.9% pipeline-overlap that a closed pool binary can't
carry. The trade-off is variance: solo is an all-or-nothing block lottery.

## Operations (host-side helpers)

Optional but recommended for an unattended rig. Run them detached on the Linux box:

```bash
# from your clone on the Linux box:
mkdir -p ops-logs
nohup bash scripts/empty-block-keeper.sh >> ops-logs/empty-block-keeper.log 2>&1 </dev/null & disown
nohup bash scripts/mining-watchdog.sh    >> ops-logs/mining-watchdog.log    2>&1 </dev/null & disown
```

- **`scripts/empty-block-keeper.sh`** - between heights 130,000 and 132,000 a coinbase-only
  block pays **half** the subsidy. The keeper holds a tiny self-spend in the mempool so your
  blocks stay `nTx>=2` (full subsidy). Self-exits at 132,000.
- **`scripts/mining-watchdog.sh`** - samples the solve counter / tip / peers; on a stall it
  alerts (`ops-logs/ALERT.txt`, optional push via `ALERT_CMD`) and auto-restarts the miner,
  escalating to CRITICAL if a restart can't fix it (as a consensus stall wouldn't).
- **`make deploy`** - minimal-downtime version bump: builds the new image while the miner
  keeps mining, swaps on success, and times the warmup gap. See `docs/minimal-downtime-deploy.md`.

## Monitor

```bash
make status                                                                       # sync + difficulty + live solve rate
docker compose exec btx-miner btx-cli -datadir=/data getblockchaininfo            # sync state
docker compose exec btx-miner btx-cli -datadir=/data getmininginfo                # difficulty, chain_guard
docker compose exec btx-miner btx-cli -datadir=/data -rpcwallet=miner getbalance  # what you've mined
cat ./btx-data/miner-address.txt                                                  # your reward address
```

## Fast-start / snapshot (0.32.11)

The entrypoint loads an assumeutxo snapshot to skip most of the initial sync. 0.32.11 added
consensus pins for shielded snapshots, so the bundled fast-start snapshot loads only with
`allowunpinnedshieldedsnapshot=1` - the entrypoint sets this automatically (idempotent, so
existing datadirs pick it up on the next restart). `prune=0` means the node rebuilds the
unshield-velocity state locally after loading, so forcing the load is safe.

## Stop / clean up

```bash
docker compose down        # stop
rm -rf ./btx-data          # delete chain data + wallet (back it up first if you mined anything)
```

## Manual fallback (if the automated path hiccups)

The compiled binaries live at `/opt/btx/bin` (already on `PATH` in the image),
so you can drive them by hand:

```bash
docker compose run --rm --entrypoint bash btx-miner
# inside the container:
BTX_MATMUL_BACKEND=cuda btxd -datadir=/data -server=1 -daemon
btx-cli -datadir=/data createwallet miner
btx-cli -datadir=/data -rpcwallet=miner getnewaddress
/opt/btx-src/contrib/mining/start-live-mining.sh \
  --datadir=/data --wallet=miner \
  --address-file=/data/miner-address.txt --should-mine-command=/bin/true
```

To build a different commit, change `BTX_SOURCE_REF` in `docker-compose.yml`.
To run the signed precompiled release instead, set `BTX_INSTALL_MODE=release`
and `RELEASE_TAG=v0.32.11`; the entrypoint then runs the upstream `faststart`
installer (see `doc/linux-release-builds.md`).

## Power use

A 5090 mining full-tilt draws ~0.5 kW, roughly **$1-2/day** in electricity. For best
nonces/watt rather than peak rate, `scripts/gpu-tune.service` locks the clock + caps power
(~346 W at ~99% of the hashrate); install it per the comments in that file.

## Credits / thanks

This repo is just packaging + tuning on top of other people's hard work. Thanks to:

- **[`btxchain/btx`](https://github.com/btxchain/btx)** - the BTX node, the MatMul
  proof-of-work, and the CUDA backend this builds and mines with. Everything here
  compiles a pinned commit of it.
- **[`dexbtx/minebtx`](https://github.com/dexbtx/minebtx)** (shib) - the minebtx
  pool and `dexbtx-miner` stratum orchestrator; the protocol reference for our
  v2/v3 seed + `parent_mtp` handling.

## License

Proprietary - Copyright (c) 2026 AM2 LLC. All rights reserved. See [LICENSE](LICENSE).
Third-party components (btxchain/btx and its Bitcoin Core lineage) remain under the
MIT License. matador-miner release binaries ship under their own end-user terms.
