# matador-miner - a fast standalone miner for `btxchain/btx`

![MATADOR - fearless BTX MatMul miner](docs/matador.png)

A **standalone, decoupled** miner for the BTX MatMul proof-of-work. It can solo-mine
against your own `btxd` (`getblocktemplate` -> `submitblock`) or pool-mine directly
against [minebtx](https://minebtx.com/) / dexbtx-style pools, so updating the miner never restarts your node.
Built to be fast (CUDA async overlap is baked in) and to keep solo blocks self-custodied.

**Backends**

| Backend | Status |
|---------|--------|
| NVIDIA CUDA single-GPU fat binary (`sm_80`, `sm_86`, `sm_89`, `sm_90`, `sm_120`) | working today |
| NVIDIA multi-GPU | on the roadmap |
| Apple Silicon (Metal) | working |
| AMD (HIP/ROCm) | sidecar bridge to companion C++/HIP solver [`amdbtx`](https://github.com/thekillsquad007/amdbtx) |

**Estimated BTX MatMul rates**

| Hardware | Backend | Estimated rate | Notes |
|----------|---------|----------------|-------|
| NVIDIA RTX 5090 / Blackwell `sm_120` | CUDA | ~19.5k-20.5k nonce/s | Live `matador-miner` pool rate on `pc` with async overlap on. |
| Apple M4 Max | Metal | ~1.1k-1.3k nonce/s | Working macOS arm64 build; useful for dev / spare-Mac mining. |
| Other NVIDIA CUDA GPUs | CUDA | not benchmarked here | Release binaries include Ampere/Ada/Hopper/Blackwell cubins: `sm_80`, `sm_86`, `sm_89`, `sm_90`, `sm_120`. Measure locally. |
| Multiple NVIDIA GPUs | CUDA | not available yet | True multi-GPU scheduling is still roadmap. |

> **AMD GPUs (Radeon / Instinct):** matador can hand HIP/ROCm solves to the companion
> C++/HIP sidecar from [`amdbtx`](https://github.com/thekillsquad007/amdbtx). Build it with
> `private/matador-miner/build-hip-sidecar.sh`, then run with `--backend hip`; release bundles
> auto-discover `bin/btx-gbt-solve-hip` next to the miner. Same network, same pool - just the right
> solver for the hardware.
> The sidecar build emits a fat HIP binary for common AMD code-object targets by default; set
> `HIP_ARCHS="gfx1030 gfx1100"` to narrow the build for a known rig.

## Quick start (just want to mine?)

**[⬇️ Download the latest release](https://github.com/vanities/matador-miner/releases/latest)** -
Linux x86-64 (NVIDIA CUDA, with the AMD/HIP sidecar in the bundle) and macOS arm64 (Apple Metal).

**1. Install** - Linux, one line (fetches the latest, verifies the sha256, installs to `/usr/local/bin`):

```bash
curl -fsSL https://raw.githubusercontent.com/vanities/matador-miner/main/install.sh | bash
```

**2. Mine** - pick one:

**Pool** - no node to run, just point it at the pool with your payout address:

```bash
matador-miner --mode pool \
  --pool stratum+tcp://stratum.minebtx.com:3333 \
  --worker rig1 \
  --payoutaddress btx1...your-btx-address
```

**Solo** - against your own synced `btxd` (this repo's `make solo`, or any `btxd` v0.32.12+ with
RPC on); you keep 100% of every block, no pool fee:

```bash
matador-miner \
  --payoutaddress btx1...your-btx-address \
  --rpccookiefile ~/.btx/.cookie        # or --rpcuser/--rpcpassword
# solo is the default mode; add --rpcconnect 127.0.0.1 --rpcport 19334 if btxd isn't on the defaults
```

**Prefer a config file?** The release bundles ship `config.example.nvidia.json`,
`config.example.amd.json`, and `config.example.mac.json` - copy the one for your GPU, set your
payout/worker, and just run (it auto-loads `./matador.json`):

```bash
cp config.example.nvidia.json matador.json   # or config.example.amd.json / .mac.json
$EDITOR matador.json                          # set payout address + worker
./bin/matador-miner
```

You should see `accepted` shares (pool) or a block search, with a `nonce/s` / `scan=…MN/s`
heartbeat, within seconds. That's it.

Want the full bundle layout, Apple/AMD specifics, or the self-contained Docker node? See
[Install the prebuilt miner](#install-the-prebuilt-miner-matador-miner) and the sections below.

---

## Or: the all-in-one Docker node + miner (`make solo`)

Everything above is the **standalone miner** - a single binary you point at any `btxd`. The
rest of this README is the *other* way to use this repo: a **self-contained Docker stack**
that runs its own pinned BTX full node **and** GPU solo-mines against it, with the node,
miner, and wallet all sandboxed from your host. Reach for this if you'd rather run your own
node end-to-end than mine against an existing one.

> **Upstream / official node:** [`github.com/btxchain/btx`](https://github.com/btxchain/btx). Pinned to **v0.32.12** (commit [`f3c9eb77`](https://github.com/btxchain/btx/commit/f3c9eb77fa547a48862bc9bcec5f0d6acf4f0bb8)). This repo **compiles that exact commit from source** with the CUDA MatMul backend by choice - it guarantees native codegen for the supported NVIDIA arch set (`sm_80/86/89/90/120`) and a byte-reproducible build. To run the GPG-signed prebuilt instead, set `BTX_INSTALL_MODE=release` + `RELEASE_TAG=v0.32.12` in `docker-compose.yml`.
>
> **Consensus timeline (upgrade before each height or you fork off the network):** block **125,000** shielded sunset + MatMul nonce-seed **v2**; **130,000** temporary empty-block subsidy penalty; **130,500** MatMul seed-derivation **v3** (binds each nonce's seed to the parent block's `parent_mtp`); **132,000** forward consensus (shielded-exit velocity cap, empty-block penalty ends); **135,000** shielded-unshield velocity-cap quota ends (added in v0.32.12). 0.32.12 covers all of these.

**What `make solo` does:**

- Compiles `btxd` + `btx-cli` + the CUDA MatMul backend from a pinned commit (**0.32.12**) in the Docker build.
- Runs that full node in Docker (archival, `prune=0`, so shielded-state rebuilds never fail).
- Creates/uses a local wallet under `./btx-data`.
- Runs a supervised GPU **solo**-mining loop on BTX's MatMul proof-of-work.

## Safety model (why this is the contained way to try it)

- Runs entirely in a container; the node/miner cannot see your host filesystem.
- **Source build:** compiles a single, pinned, immutable commit (0.32.12) from
  [`github.com/btxchain/btx`](https://github.com/btxchain/btx). The signed
  release key is integrity-only (self-published, no independent vouching), so
  commit pinning is comparable trust - and native CUDA cubins for `sm_80/86/89/90/120`
  avoid depending on generic PTX JIT for supported NVIDIA generations. Acceptable **only** because everything runs sandboxed here with
  no funds at stake; do not extend trust beyond this container. Set
  `BTX_INSTALL_MODE=release` to run the signed prebuilt instead.
- Mines to a wallet generated **inside your mounted `./btx-data`** so the wallet
  state and keys persist outside the container.
- Publishes the node RPC port only on host loopback (`127.0.0.1:19334`) so an
  external miner can reach it via localhost or an SSH tunnel; cookie auth is still
  required and nothing is exposed to the LAN/internet.

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
make solo        # build (first run) + solo-mine on 0.32.12
make help        # all targets: up/down/logs/status/balance/backup/restore/deploy/...
```

The first (cold) build **compiles btxd + the CUDA backend from source** - a one-time
~20-40 min step, with the NVIDIA CUDA toolchain pulled into the Docker build, not your
host. After that it syncs the chain (fast-start / assumeutxo keeps this short - see
[Fast-start](#fast-start--snapshot-03212)), prints **your** mining address, and starts a
supervised solo-mining loop. Rebuilds reuse Docker's layer cache **plus ccache**, so a
`BTX_SOURCE_REF` bump recompiles only the translation units that actually changed
(minutes, not a full rebuild).

## Install the prebuilt miner (`matador-miner`)

Prefer a single binary over the Docker stack? `matador-miner` is a **standalone solo + pool
GPU miner**: solo pulls work from **your own `btxd`** via `getblocktemplate`, solves on the
GPU, and submits with `submitblock`; pool mode talks directly to
[minebtx](https://minebtx.com/) / dexbtx-style stratum pools. It is **decoupled from the node**, so updating the miner never restarts
`btxd` (no shielded-state warmup, no lost propagation standing). Linux x86-64 release
assets are CUDA fat binaries for `sm_80`, `sm_86`, `sm_89`, `sm_90`, and `sm_120`
(Ampere through Blackwell); macOS arm64 assets use Metal.

**Quick start (release bundle — recommended).** Each release ships a per-platform
`*-bundle.tar.gz` with the miner, GPU-specific config templates, and (on Linux) the
AMD/HIP sidecar. Grab your platform's bundle from the
[latest release](https://github.com/vanities/matador-miner/releases), then:

```bash
# matador-miner-<ver>-linux-x86_64-bundle.tar.gz   NVIDIA CUDA + bundled AMD/HIP sidecar
# matador-miner-<ver>-macos-arm64-bundle.tar.gz    Apple Metal
curl -fsSLO "<bundle-url>" && curl -fsSLO "<bundle-url>.sha256"
sha256sum -c matador-miner-*-bundle.tar.gz.sha256        # must print: OK  (shasum -a 256 on macOS)
tar xzf matador-miner-*-bundle.tar.gz && cd matador-miner-*/
cp config.example.nvidia.json matador.json    # or config.example.amd.json / config.example.mac.json
$EDITOR matador.json                          # set your payout address + worker
./bin/matador-miner                           # auto-loads ./matador.json and starts mining
```

For multi-GPU rigs, set `"gpus": [0, 1, 2]` in `matador.json` (or pass
`--gpus 0,1,2`). This is deliberately simple: matador starts one ordinary miner
process per GPU, scopes visible devices for each child, appends worker suffixes
like `rig1-gpu0`, and increments API ports (`4060`, `4061`, ...). No cross-GPU
batching or autotuning is attempted.

Prefer just the bare binary? Use the one-liner below instead.

**One-line install** (downloads the newest published release, including prereleases,
verifies the sha256, installs to `/usr/local/bin`):

```bash
curl -fsSL https://raw.githubusercontent.com/vanities/matador-miner/main/install.sh | bash
```

Pin a version or change the install dir with env vars:
`VERSION=v0.1.0 PREFIX=$HOME/.local/bin` before the pipe. Prefer to inspect first? Read
[`install.sh`](install.sh), or do it by hand:

```bash
api=https://api.github.com/repos/vanities/matador-miner/releases
url=$(curl -fsSL "$api" | grep -oE '"browser_download_url": *"[^"]+linux-x86_64"' | cut -d'"' -f4)
curl -fsSLO "$url" && curl -fsSLO "$url.sha256"          # binary + checksum
sha256sum -c "$(basename "$url").sha256"                 # must print: OK
chmod +x "$(basename "$url")" && sudo mv "$(basename "$url")" /usr/local/bin/matador-miner
matador-miner --help
```

**Solo-mine** against a synced `btxd` (this repo's `make node`, or any `btxd` v0.32.12+ with
RPC enabled):

```bash
matador-miner \
  --chain main \
  --payoutaddress btx1...your-P2MR-address \   # getnewaddress from a current btx wallet
  --rpccookiefile ~/.btx/.cookie               # or --rpcuser/--rpcpassword
# extras: --rpcconnect 127.0.0.1 --rpcport 19334 --maxtries N
#         --dev-fee 1 (default; 0 disables)  --dev-address <addr>  LOG_LEVEL=debug
```

**Pool-mine** without running a node locally:

```bash
matador-miner \
  --mode pool \
  --pool stratum+tcp://stratum.minebtx.com:3333 \
  --worker rig1 \
  --payoutaddress btx1zcf4z36asua8ylchysphgwfgyfr8267vvznth826epden7lar4fnqvy9gzv
```

Useful minebtx links:

- Pool homepage / installer: [`minebtx.com`](https://minebtx.com/)
- Live pool dashboard: [`pool.minebtx.com`](https://pool.minebtx.com/)
- Reference pool/client source: [`github.com/dexbtx/minebtx`](https://github.com/dexbtx/minebtx)

For unattended rigs, use a JSON config with ordered failover pools plus the local read-only
API/watchdog:

```bash
cp config.example.nvidia.json matador.json   # or config.example.amd.json / config.example.mac.json
$EDITOR matador.json                         # set payout address + worker
./bin/matador-miner                          # auto-loads ./matador.json
curl -s http://127.0.0.1:4060/health
curl -s http://127.0.0.1:4060/summary   # shares, nonces, pools, watchdog, GPU temp/power/util
curl -s http://127.0.0.1:4060/pools
scripts/matador-status.sh                # readable dashboard for the same API
```

See [`docs/config.example.nvidia.json`](docs/config.example.nvidia.json),
[`docs/config.example.amd.json`](docs/config.example.amd.json),
[`docs/config.example.mac.json`](docs/config.example.mac.json), and
[`docs/matador-standalone-ops.md`](docs/matador-standalone-ops.md).

- **Solo + your keys only.** It submits to *your* `btxd` over **localhost RPC** and holds
  **no wallet keys**; mined coins pay the `--payoutaddress` you provide.
- **1% dev fee, time-based + transparent.** Like Claymore/PhoenixMiner/T-Rex, it points the
  coinbase at the dev address for ~1% of wall-clock time (~36s/hr) and **logs every
  entry/exit** of that window. Turn it off with `--dev-fee 0`.
- **Pool failover + self-watchdog.** Pool mode supports ordered `pools[]`, reconnect/failover
  on connection loss, a safe reject-streak watchdog, and loopback-only status endpoints.
- **Warning-only thermal watchdog.** `/summary` and logs report GPU temp/power warnings, but
  the miner does not change clocks, fans, power limits, or restart itself.
- **AMD/ROCm sidecar bridge.** `--backend hip` / `--backend rocm` delegates pool and solo
  solves to the external C++/HIP `btx-gbt-solve-hip` sidecar. Bundles auto-discover
  `bin/btx-gbt-solve-hip`; use `--hip-solver` or config `sidecars.hip` only for custom layouts.
  If the sidecar is missing/fails, matador logs the reason and falls back to its in-process path.
  AMD telemetry can use `rocm-smi` when present.
- Closed-source binary (AM2 LLC); **verify the sha256** before running. `LOG_LEVEL=debug`
  for full per-stage solve timing, every template, every submit (accept/reject + reason).

## Tuning

**`matador-miner` self-tunes the solver internals** (input generation, batch size, prefetch
depth, pipeline overlap) for the detected GPU, so there is very little to turn. The only knobs
you normally touch:

| Knob | Default | What it does | When to change |
| --- | --- | --- | --- |
| `solver_threads` | 1 | CPU feeder threads per GPU | Raise (e.g. 8) if the GPU isn't saturated; too many starves a fast card |
| `overlap` | true | pipeline-overlap (+22.9%, byte-exact) | Leave on; set false only for a serial A/B baseline |
| `backend` | cuda | `cuda` / `metal` / `cpu` / `hip`/`rocm` | Match your hardware |
| `--dev-fee` | 1 | dev-fee % of wall-clock time | `0` disables |

If instead you run the **upstream [`dexbtx-miner`](https://github.com/dexbtx/minebtx) pool
client** (its `~/.dexbtx-miner/config.yaml`), these are the levers that actually matter, per its
`docs/TUNING.md`:

| Knob | Recommended | Notes |
| --- | --- | --- |
| `gpu_inputs` | **your GPU count** | It's a *count*, not a flag: `0` = CPU-gen (dead since block 125,000, gives 0-20% util), `1` = single GPU (mandatory for one card), `N` = N GPUs in the rig |
| `solver_batch_size` | **128** | Sweet spot. 256+ degrades util; 1024 crashes the CUDA buffer pool. Bigger is a trap |
| `solver_threads` | 8 (12-16 for slow cards / 5090) | Too many starves a fast card, too few starves a slow one |
| `solver_prepare_workers` | 16 (~2x threads; 24 for slow cards) | Feeds the solver; under-provisioning bottlenecks prep |
| `solver_prefetch_depth` | 8 | Universal sweet spot |
| `nonces_per_slice` | leave huge (default ~1e11) | The real cap is the 30s/slice timeout; a low value just churns slices |

**Golden rule for either:** change **one** knob at a time and confirm on the live miner, not a
synthetic bench. Watch util/power with `nvidia-smi --query-gpu=utilization.gpu,power.draw,temperature.gpu --format=csv -l 2`
alongside the accepted-share rate; aim for ~90%+ util. Reference points: a 3090/A6000 is GA102
(`sm_86`), a 4090 is `sm_89`, a 5090 is `sm_120`.

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

## Fast-start / snapshot (0.32.12)

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
and `RELEASE_TAG=v0.32.12`; the entrypoint then runs the upstream `faststart`
installer (see `doc/linux-release-builds.md`).

## Power use

A 5090 mining full-tilt draws ~0.5 kW, roughly **$1-2/day** in electricity. For best
nonces/watt rather than peak rate, `scripts/gpu-tune.service` locks the clock + caps power
(~346 W at ~99% of the hashrate); install it per the comments in that file.

## Help wanted - benchmarks & testing

Only the RTX 5090 is benchmarked here. The CUDA binary ships codegen for Ampere/Ada/Hopper
too, and the AMD/HIP sidecar is **built but not yet validated on real AMD hardware** - so if
you run it on anything else, your numbers genuinely help:

- **NVIDIA (any `sm_80`-`sm_120` card):** the `nonce/s` and `scan=...MN/s` from the `[stats]`
  line, plus your card + driver version.
- **AMD (RDNA / CDNA, `--backend hip`):** confirm the bundled `btx-gbt-solve-hip` solves and
  lands shares, with your GPU + ROCm version. (On ROCm 6.x, build the sidecar from
  [amdbtx](https://github.com/thekillsquad007/amdbtx) and point `--hip-solver` at it.)
- **Apple Silicon (M1-M5, `--backend metal`):** `nonce/s` / `scan` per chip.

Easiest way to share: `scripts/matador-status.sh` (or `curl -s http://127.0.0.1:4060/summary`)
prints a clean rig snapshot - open an issue with that output + your OS/driver, or PR a row into
the rates table at the top. Bug reports and weird-hardware/driver/pool edge cases are just as
welcome.

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
