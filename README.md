# matador-miner - isolated GPU miner for `btxchain/btx`

![MATADOR - fearless BTX MatMul miner](docs/matador.png)

> **Solo mining is the working path today** (`make solo`): a sandboxed BTX full node + CUDA
> MatMul miner pinned to **0.32.11**, keeping 100% of every block it finds. **MATADOR**
> (`make matador`) is this repo's custom CUDA pool miner, but BTX's **v3 consensus
> (height 130,500+) currently blocks pool mining** for it - see [Solo vs pool](#solo-vs-pool).

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

## Solo vs pool

**Solo (`make solo`) is recommended and currently the only fully-working mode.** You run
your own node + our CUDA solver, keep 100% of every block (no fee), and saturate the GPU
(~100% on a 5090). The trade-off is variance: solo is an all-or-nothing block lottery.

**Pool mining is currently blocked by BTX v3.** At height 130,500+ each nonce's MatMul seed
binds to `parent_mtp` (the parent block's median-time-past). The minebtx stratum protocol
does **not** broadcast `parent_mtp`, so:

- `make pool` - the official `btx-gbt-solve` runs but is GPU-starved (~3-30%).
- `make matador` - our integrated CUDA pool miner runs once fed `parent_mtp` from a local
  node, but its re-derived seeds diverge from the pool's consensus, so shares are rejected.

So for now, **solo is the play.** Pool support comes back if a pool broadcasts `parent_mtp`
(some newer ones, e.g. BitMinerPool, do) and the seed derivation is reconciled.
`scripts/pool-probe.py <host> <port> <btx-addr>` passively inspects any pool's job format
(no GPU, no mining, won't disturb a running solo miner) to check what a pool conveys.

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
  pool and the open-source `dexbtx-miner` stratum orchestrator that the pool path
  is modeled on.
- **[`thekillsquad007/btx-nvidia-miner`](https://github.com/thekillsquad007/btx-nvidia-miner)**
  - the integrated CUDA miner that **MATADOR** (`make matador`) is forked from.

## License

[GNU General Public License v3.0](LICENSE)
