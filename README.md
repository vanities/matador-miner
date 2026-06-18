# matador-miner

![MATADOR - fearless BTX MatMul miner](docs/matador.png)

**A fast, headless GPU miner for [`btxchain/btx`](https://github.com/btxchain/btx) (BTX) -
the MatMul proof-of-work. One static binary. Solo or pool. NVIDIA, Apple, AMD. Self-updating
and fleet-ready.**

Point it at your own node and keep 100% of every block, or pool-mine against
[minebtx](https://minebtx.com/) with one flag. It is fully decoupled from the node, so the
miner can update or restart without ever touching `btxd`.

```bash
# install + start mining a pool in two lines:
curl -fsSL https://raw.githubusercontent.com/vanities/matador-miner/main/install.sh | bash
matador-miner --mode pool --pool stratum+tcp://stratum.minebtx.com:3333 \
  --worker rig1 --payoutaddress btx1zcf4z36asua8ylchysphgwfgyfr8267vvznth826epden7lar4fnqvy9gzv
```

## Why matador

- **One binary, every platform.** A single static release runs on NVIDIA (CUDA), Apple
  Silicon (Metal), and AMD (HIP/ROCm via a bundled sidecar). The backend auto-detects.
- **Solo *or* pool.** Solo mines against your own `btxd` (`getblocktemplate` -> `submitblock`)
  and keeps every block self-custodied; pool mode talks stratum to minebtx/dexbtx pools for
  steady payouts. Same solver either way.
- **Self-updating.** Checks GitHub on a schedule and atomically upgrades itself - same PID,
  no node restart - so a fleet stays current with zero ops. Fleet-safe defaults; opt out any time.
- **Fleet-ready.** Run one coordinator (your node + a least-privilege work proxy + a telemetry
  dashboard) and point any number of disposable rigs at it. They hop on and off, share one
  wallet, and never collide.
- **Observable.** A read-only JSON status API (on by default, loopback) for dashboards,
  watchdogs, and the fleet hub.

## Supported hardware

| Backend | Status |
|---|---|
| NVIDIA CUDA - fat binary (`sm_80` / `86` / `89` / `90` / `120`, Ampere -> Blackwell) | working |
| NVIDIA multi-GPU | working |
| Apple Silicon (Metal) | working |
| AMD (HIP/ROCm) | sidecar bridge to the companion solver in [`amdbtx`](https://github.com/thekillsquad007/amdbtx) |

> Older NVIDIA cards (Pascal / Volta / Turing, e.g. GTX 10-series) are not covered by the main
> CUDA-13 build, but an **experimental `-legacy` build** exists in the
> [releases](https://github.com/vanities/matador-miner/releases) - unvalidated, feedback welcome.

**Measured rates** (matador `--mode pool` on rented Vast.ai GPUs at stock power, ~60s
steady-state window, June 2026; all NVIDIA cards 95-100% util, 0 rejects. Your numbers
welcome - see [Help wanted](#help-wanted)):

| Hardware | Backend | nonce/s | Power | nonce/s per W | Notes |
|---|---|--:|--:|--:|---|
| RTX 5090 (Blackwell `sm_120`) | CUDA | ~18.8k | ~452W | ~42 | Vast 12-vCPU host; tuned local peak ~20k. |
| RTX 4090 (Ada `sm_89`) | CUDA | ~14.6k | ~383W | ~38 | |
| RTX 6000 Ada (`sm_89`) | CUDA | ~10.5k | ~290W | ~36 | |
| A100 SXM4 (Ampere `sm_80`) | CUDA | ~7.1k | ~233W | ~31 | Integer/ALU PoW, no tensor cores, so it sits below the 4090. |
| RTX 3090 (Ampere `sm_86`) | CUDA | ~5.9k | ~248W | ~24 | |
| RTX 3060 (Ampere `sm_86`) | CUDA | ~1.5k | ~105W | ~14 | |
| H100 (Hopper `sm_90`, SXM) | CUDA | ~12.5k | - | - | Community-reported; FP32 tier (~4090-class, no tensor cores), not its AI tier. |
| Apple M4 Max | Metal | ~1.1k-1.3k | - | - | Spare-Mac / dev mining. |

NVIDIA numbers collected with `scripts/vast-bench.sh` (rent, mine the pool, rank by
nonce/watt). AMD was not measured: Vast.ai had zero AMD GPUs in inventory at the time.

## Quick start

**1. Install** (Linux one-liner: fetches the latest release, verifies the sha256, installs to
`/usr/local/bin` or `~/.local/bin`):

```bash
curl -fsSL https://raw.githubusercontent.com/vanities/matador-miner/main/install.sh | bash
```

**2. Mine.** The backend **auto-detects** (CUDA on NVIDIA, Metal on Apple Silicon), so no flag
is needed. **AMD is the one exception: add `--backend hip`.**

```bash
# Pool - no node required:
matador-miner --mode pool \
  --pool stratum+tcp://stratum.minebtx.com:3333 \
  --worker rig1 --payoutaddress btx1zcf4z36asua8ylchysphgwfgyfr8267vvznth826epden7lar4fnqvy9gzv

# Solo - against your own btxd (v0.32.12+, RPC on); keep 100% of every block, no fee:
matador-miner \
  --payoutaddress btx1zcf4z36asua8ylchysphgwfgyfr8267vvznth826epden7lar4fnqvy9gzv \
  --rpccookiefile ~/.btx/.cookie          # or --rpcuser/--rpcpassword
# solo is the default mode; add --rpcconnect/--rpcport if btxd isn't on 127.0.0.1:19334
```

You should see a `nonce/s` / `scan=...MN/s` heartbeat within seconds. That's it. The examples
use the project's payout address so they run as-is - **set `--payoutaddress` to your own
`btx1...` to mine to yourself.**

**Prefer a config file?** Copy the template for your GPU and just run it:

```bash
cp config.example.nvidia.json matador.json   # or config.example.amd.json / .mac.json
$EDITOR matador.json                          # set payout address + worker
matador-miner                                 # auto-loads ./matador.json
```

## Install in detail

**Release bundle (recommended).** Each release ships a per-platform `*-bundle.tar.gz` with the
binary, GPU config templates, and (on Linux) the AMD/HIP sidecar:

```bash
# matador-miner-<ver>-linux-x86_64-bundle.tar.gz   NVIDIA CUDA + AMD/HIP sidecar
# matador-miner-<ver>-macos-arm64-bundle.tar.gz    Apple Metal
curl -fsSLO "<bundle-url>" && curl -fsSLO "<bundle-url>.sha256"
sha256sum -c matador-miner-*-bundle.tar.gz.sha256     # must print OK   (shasum -a 256 on macOS)
tar xzf matador-miner-*-bundle.tar.gz && cd matador-miner-*/
cp config.example.nvidia.json matador.json && $EDITOR matador.json
./bin/matador-miner
```

**Bare binary.** The one-liner above, or pin/redirect it: `VERSION=v0.4.0 PREFIX=$HOME/.local/bin`
before the pipe. To verify by hand instead of trusting the script:

```bash
api=https://api.github.com/repos/vanities/matador-miner/releases
url=$(curl -fsSL "$api" | grep -oE '"browser_download_url": *"[^"]+linux-x86_64"' | cut -d'"' -f4)
curl -fsSLO "$url" && curl -fsSLO "$url.sha256"
sha256sum -c "$(basename "$url").sha256"              # must print OK
chmod +x "$(basename "$url")" && sudo mv "$(basename "$url")" /usr/local/bin/matador-miner
matador-miner --help
```

## Auto-update

On by default: the miner checks GitHub releases at startup and every 30 min, and when a newer
one ships it downloads the platform binary, verifies its sha256, atomically swaps itself, and
re-exec's into it **with the same PID and no `btxd` restart**. Works the same under systemd,
`nohup`, `tmux`, `screen`, or a foreground shell.

> **Requirement:** the binary must live in a path **writable by the user running it**.
> `install.sh` uses `~/.local/bin` when you're not root, which works out of the box. If you
> `sudo`-install to `/usr/local/bin` but run as a normal user, the self-update can't replace
> the file (it logs `cannot replace binary ...` and keeps the old one) - run from a user-owned
> dir instead, e.g. `~/.local/bin` or an `/opt/matador/bin` you own.

Tune or disable: `--update-interval-s <sec>` (`0` = startup-only), `--update-channel prerelease`,
`--min-version-age-s <sec>` (bake time), or `--no-auto-update` (check + notify only). Details in
[`docs/matador-standalone-ops.md`](docs/matador-standalone-ops.md#auto-update).

## Configure

`matador-miner` picks safe defaults for the detected hardware, so there is little to turn:

| Knob (config / flag) | Default | Notes |
|---|---|---|
| `gpus` / `--gpus 0,1,2` | first GPU | multi-GPU fan-out; each card gets its own worker suffix + API port |
| `backend` / `--backend` | auto | `cuda` / `metal` / `hip` / `rocm` / `cpu` - only AMD needs it set |
| `pools` / `--pool` | - | one endpoint or an ordered failover list (pool mode) |

Full config keys and the systemd unit are in
[`docs/matador-standalone-ops.md`](docs/matador-standalone-ops.md). Example configs:
[nvidia](docs/config.example.nvidia.json) / [amd](docs/config.example.amd.json) /
[mac](docs/config.example.mac.json).

Pool: **[minebtx](https://minebtx.com/)** is the default (the examples use
`stratum+tcp://stratum.minebtx.com:3333`) -
[live dashboard](https://pool.minebtx.com/) -
[dexbtx/minebtx source](https://github.com/dexbtx/minebtx). Any dexbtx-style pool works too,
e.g. [bitminerpool.xyz](https://bitminerpool.xyz/#miners) - just point `--pool` at its stratum
endpoint.

## Run a fleet

Mine across many machines from one node and one dashboard. A **coordinator** runs your `btxd`
+ `matador-gbt-proxy` (a least-privilege work proxy: token auth, only `getblocktemplate` /
`submitblock`) + `matador-hub` (telemetry + dashboard). **Workers** are disposable - no node,
no chain state - so they hop on and off with zero warmup. They share one payout wallet, and a
per-rig coinbase extranonce keeps their work disjoint (no duplicate effort), exactly like a
pool partitions across miners.

```bash
# on the coordinator:
FLEET_TOKEN=... NODE_COOKIE=~/.btx/.cookie \
  HUB_WORKERS="rig1=http://10.0.0.11:4060,rig2=http://10.0.0.12:4060" \
  scripts/matador-coordinator.sh --listen 10.0.0.1
# dashboard -> http://10.0.0.1:4070
# workers   -> matador-miner --mode solo --rpcconnect 10.0.0.1 --rpcport 4071 \
#                --rpcuser rig1 --rpcpassword "$FLEET_TOKEN" --worker rig1 --payoutaddress btx1...
```

Workers can also **fall back to a pool** if the coordinator drops (`--fallback-pool ...`) and
**idle-gate** the GPU so a workstation only mines when it's free (`--should-mine-command ...`).
Full copy-paste setup (VPN + laptop dashboard, fallback, idle-gate) is in
**[`docs/matador-fleet.md`](docs/matador-fleet.md)**.

## Monitor

A read-only HTTP status API runs by default on `127.0.0.1:4060` (`--no-api` to disable,
`--api-listen` to bind a LAN/VPN address). It never exposes RPC credentials or pool passwords.

```bash
curl -s http://127.0.0.1:4060/health     # {"status":"ok"}
curl -s http://127.0.0.1:4060/summary    # version, mode, backend, shares, nonces, GPU temp/power, update state
curl -s http://127.0.0.1:4060/pools      # effective failover pool list
scripts/matador-status.sh                # readable terminal dashboard over the same API
```

`/summary` is the one to scrape for a dashboard - shares, live `nonce/s`, per-GPU
util/power/temp, watchdog state, and the auto-update block (running vs latest version). For
multi-GPU rigs each child increments the port: `4060`, `4061`, ...

## AMD / ROCm

Pass `--backend hip` (or `rocm`) and matador hands solves to the companion C++/HIP solver
`btx-gbt-solve-hip` from [`amdbtx`](https://github.com/thekillsquad007/amdbtx). Linux release
bundles include it and auto-discover `bin/btx-gbt-solve-hip`; otherwise build it with
`private/matador-miner/build-hip-sidecar.sh` (set `HIP_ARCHS="gfx1030 gfx1100"` to narrow it)
or point `--hip-solver` / config `sidecars.hip` at your own. The bundled sidecar links **ROCm 7**;
on ROCm 6.x, build it yourself from amdbtx. If the sidecar is missing or fails, matador logs why
and falls back to its in-process path.

## Reliability

Pool mode supports ordered `pools[]` failover, a reject-streak watchdog that triggers a safe
reconnect, optional pool-fallback for solo workers, and a warning-only thermal monitor (it never
changes clocks, fans, or power limits). A 1% time-based dev fee funds development - the coinbase
pays the dev address for ~36s of each hour, logged on entry and exit.

## Trust & self-custody

- **Self-custody.** Solo submits to *your* `btxd` over localhost RPC and holds **no wallet keys**;
  rewards pay the `--payoutaddress` you provide.
- **Closed-source binary.** **Verify the sha256** of every download before running it
  (the bundle and one-liner do this for you). Use `LOG_LEVEL=debug` for troubleshooting.
- **Loopback by default.** The status API binds `127.0.0.1`; only expose it on a LAN/VPN you
  control.

## Help wanted

Only the RTX 5090 is benchmarked first-hand, and the AMD sidecar is **built but not yet validated
on real AMD hardware** - so numbers from other gear genuinely help:

- **NVIDIA (`sm_80`-`sm_120`):** `nonce/s` + `scan=...MN/s` from the `[stats]` line, plus card +
  driver.
- **AMD (`--backend hip`):** confirm `btx-gbt-solve-hip` solves and lands shares, with GPU + ROCm
  version.
- **Apple Silicon (`--backend metal`):** `nonce/s` per chip.

Easiest way to share: `scripts/matador-status.sh` (or `curl -s .../summary`) prints a clean
snapshot - open an issue with it + your OS/driver, or PR a row into the rates table.

## Credits

- **[`btxchain/btx`](https://github.com/btxchain/btx)** - the BTX node, the MatMul proof-of-work,
  and the CUDA backend this builds and mines with.
- **[`dexbtx/minebtx`](https://github.com/dexbtx/minebtx)** (shib) - the minebtx pool and stratum
  orchestrator; the protocol reference for the v2/v3 seed + `parent_mtp` handling.
- **[`thekillsquad007/amdbtx`](https://github.com/thekillsquad007/amdbtx)** - the companion
  C++/HIP solver (`btx-gbt-solve-hip`) matador bridges to for AMD/ROCm mining.

## License

Proprietary - Copyright (c) 2026 AM2 LLC. All rights reserved. See [LICENSE](LICENSE).
Third-party components (btxchain/btx and its Bitcoin Core lineage) remain under the MIT License.
matador-miner release binaries ship under their own end-user terms.
