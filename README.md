# matador-miner - standalone mining for `btxchain/btx`

![MATADOR - fearless BTX MatMul miner](docs/matador.png)

A **standalone, decoupled** miner for the BTX MatMul proof-of-work. It can solo-mine
against your own `btxd` (`getblocktemplate` -> `submitblock`) or pool-mine directly
against [minebtx](https://minebtx.com/) / dexbtx-style pools, so updating the miner never restarts your node.
Designed to keep solo blocks self-custodied.

**Backends**

| Backend | Status |
|---------|--------|
| NVIDIA CUDA fat binary (`sm_80`, `sm_86`, `sm_89`, `sm_90`, `sm_120`) | working today |
| NVIDIA multi-GPU | working today |
| Apple Silicon (Metal) | working |
| AMD (HIP/ROCm) | sidecar bridge to companion C++/HIP solver [`amdbtx`](https://github.com/thekillsquad007/amdbtx) |

**Estimated BTX MatMul rates**

| Hardware | Backend | Estimated rate | Notes |
|----------|---------|----------------|-------|
| NVIDIA RTX 5090 / Blackwell `sm_120` | CUDA | ~19.5k-20.5k nonce/s | Observed release-build pool rate. |
| NVIDIA H100 (Hopper `sm_90`, SXM) | CUDA | ~12.5k nonce/s | Community-reported. This PoW is integer/ALU work with no tensor cores, so the H100 runs at its FP32/INT32 tier (~4090-class, ~63% of a 5090), not its AI tier. Works, but a 5090 is better per watt/dollar here. |
| Apple M4 Max | Metal | ~1.1k-1.3k nonce/s | Working macOS arm64 build; useful for dev / spare-Mac mining. |
| Other NVIDIA CUDA GPUs | CUDA | not benchmarked here | Release binaries include Ampere/Ada/Hopper/Blackwell cubins: `sm_80`, `sm_86`, `sm_89`, `sm_90`, `sm_120`. Measure locally. |
| Multiple NVIDIA GPUs | CUDA | working | Configure the GPU list in `matador.json` or with `--gpus`. |

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

**Solo** - against your own synced `btxd` (any `btxd` v0.32.12+ with RPC on); you keep 100%
of every block, no pool fee:

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

Want the full bundle layout or Apple/AMD specifics? See the sections below.

---

## Install the prebuilt miner (`matador-miner`)

The [Quick start](#quick-start-just-want-to-mine) above is all most people need. This
section is the detailed reference: the release-bundle layout, the bare-binary one-liner,
by-hand checksum verification, and auto-update. Linux x86-64 release assets are CUDA fat
binaries for `sm_80`-`sm_120` (Ampere through Blackwell); macOS arm64 assets use Metal.

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
`--gpus 0,1,2`). Each configured GPU reports under its own worker/API suffix so
you can monitor cards independently.

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

**Auto-update (on by default).** The miner checks GitHub releases at startup and on an
interval (30 min), and when a newer release is out it downloads the platform binary,
verifies its sha256, atomically swaps itself, and re-exec's into it with the same PID —
**no `btxd` restart**. This works the same however you launch it: **systemd, `nohup`,
`tmux`, `screen`, or a foreground shell** (the re-exec replaces the process in place).

> **Requirement:** the binary must sit in a path **writable by the user running it**.
> `install.sh` installs to `~/.local/bin` when you're not root (works out of the box). If
> you instead `sudo`-install to `/usr/local/bin` but run the miner as a normal user, the
> self-update can't replace the file — it logs `cannot replace binary …` and keeps running
> the old version. In that case either run from a user-owned dir (e.g. `~/.local/bin`,
> `/opt/matador/bin` you own) or update manually.

Tune or disable it with `--update-interval-s <sec>` (`0` = startup-only),
`--update-channel prerelease`, `--min-version-age-s <sec>`, or `--no-auto-update` (check +
notify only). See [`docs/matador-standalone-ops.md`](docs/matador-standalone-ops.md#auto-update).

**Solo-mine** against a synced `btxd` (any `btxd` v0.32.12+ with RPC enabled):

```bash
matador-miner \
  --chain main \
  --payoutaddress btx1...your-P2MR-address \   # getnewaddress from a current btx wallet
  --rpccookiefile ~/.btx/.cookie               # or --rpcuser/--rpcpassword
# extras: --rpcconnect 127.0.0.1 --rpcport 19334 --maxtries N
#         --dev-fee 1 (default; 0 disables)  --dev-address <addr>  LOG_LEVEL=debug
```

**Pool-mine** without running a node locally — same form as the Quick start
(`--mode pool --pool stratum+tcp://stratum.minebtx.com:3333 --worker rig1 --payoutaddress btx1...`).

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

### Run a fleet (many rigs, one dashboard)

Got several rigs and want to watch them all from your laptop? Run **one coordinator**
(your `btxd` + a `getblocktemplate` proxy + a telemetry hub), point disposable workers at
it to solo-mine through it (one shared wallet, per-rig coinbase extranonce so no duplicate
work), and view a live dashboard. The miner's status API is on by default, so each rig is
hub-ready out of the box. One-command coordinator:

```bash
FLEET_TOKEN=... NODE_COOKIE=~/.btx/.cookie \
  HUB_WORKERS="rig1=http://10.0.0.11:4060,rig2=http://10.0.0.12:4060" \
  scripts/matador-coordinator.sh --listen 10.0.0.1
# dashboard: http://10.0.0.1:4070    (workers: matador-miner --mode solo --rpcport 4071 ...)
```

Full copy-paste setup (VPN-based, plus the SSH-tunnel option for viewing from a laptop),
auto pool-fallback, and the idle-gate are in
**[`docs/matador-fleet.md`](docs/matador-fleet.md#quickstart-a-bunch-of-rigs--a-laptop-dashboard)**.

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
- Closed-source binary (AM2 LLC); **verify the sha256** before running. Use `LOG_LEVEL=debug`
  when you need extra troubleshooting logs.

## Tuning

`matador-miner` chooses safe defaults for the detected hardware, so there is very little to
turn. The normal user-facing knobs are:

| Knob | Default | What it does | When to change |
| --- | --- | --- | --- |
| `gpus` / `--gpus` | first available GPU | GPU IDs to mine on | Set for multi-GPU rigs |
| `backend` | cuda | `cuda` / `metal` / `cpu` / `hip`/`rocm` | Match your hardware |
| `--dev-fee` | 1 | dev-fee % of wall-clock time | `0` disables |

If support asks you to test a rig-specific setting, change one knob at a time and compare the
accepted-share rate over a reasonable window.

## Why solo

You run your own node, keep 100% of every block (no pool fee), and stay in control of your
wallet and block submission path. The trade-off is variance: solo is an all-or-nothing block
lottery.

## Local status API

`matador-miner` exposes a small **read-only HTTP API** for dashboards, watchdogs, and fleet
hubs. It binds to `127.0.0.1` by default; keep it loopback-only unless a LAN firewall is
intentionally protecting it. It never exposes RPC credentials or pool passwords.

```bash
matador-miner --config /etc/matador-miner/config.json --api --api-port 4060
# or in matador.json: "api": { "enabled": true, "listen": "127.0.0.1", "port": 4060 }
```

For multi-GPU rigs (`gpus: [0, 1, 2]`), each child process gets its own port incremented from
the base: `4060`, `4061`, `4062`, ...

### `GET /health`

Liveness probe. Always cheap, no GPU work.

```console
$ curl -s http://127.0.0.1:4060/health
{"status":"ok"}
```

### `GET /summary` (also served at `/`)

Full runtime snapshot: counters, backend, worker, chain, public payout address, watchdog
state, GPU telemetry, and auto-update status.

```console
$ curl -s http://127.0.0.1:4060/summary | python3 -m json.tool
{
    "status": "ok",
    "version": "0.4.4",
    "mode": "solo",
    "backend": "cuda",
    "uptime_sec": 8123,
    "worker": "rig1",
    "chain": "main",
    "payoutaddress": "btx1z...",
    "shares": { "accepted": 142, "rejected": 0, "stale": 1, "dev": 2 },
    "nonces": {
        "total": 184320000,
        "batched_attempts": 184320000,
        "batched_digest_requests": 1440000,
        "batch_size": 128,
        "async_prepare": true,
        "overlapped_prepares": 1437,
        "prefetched_batches": 2
    },
    "watchdog": {
        "status": "ok",
        "last_warning": "",
        "last_action": "",
        "reject_streak": 0,
        "last_notify_age_sec": 4,
        "last_share_age_sec": 12,
        "last_accept_age_sec": 12,
        "last_nonce_age_sec": 0,
        "reconnect_requested": false
    },
    "thermal": {
        "enabled": true,
        "status": "ok",
        "warn_temp_c": 86,
        "critical_temp_c": 90,
        "warn_power_w": 0,
        "max_temp_c": 61,
        "max_power_w": 575,
        "warnings": []
    },
    "gpu_runtime": [
        {
            "gpu_uuid": "GPU-abc12345-...",
            "vendor": "nvidia",
            "util_pct": 99,
            "power_w": 575,
            "temp_c": 61
        }
    ],
    "update": {
        "current": "0.4.4",
        "latest_seen": "0.4.4",
        "last_check_age_sec": 612,
        "channel": "stable",
        "auto_update": true
    },
    "pools": [
        { "index": 0, "host": "127.0.0.1", "port": 19334, "label": "local-btxd" }
    ]
}
```

Pull a single field, e.g. for a fleet view:

```bash
curl -s http://127.0.0.1:4060/summary | python3 -c 'import sys,json; print(json.load(sys.stdin)["update"])'
scripts/matador-status.sh                # readable terminal dashboard over the same /summary
```

### `GET /pools`

The effective, ordered failover pool list (solo points at your local `btxd`).

```console
$ curl -s http://127.0.0.1:4060/pools
{"pools":[{"index":0,"host":"127.0.0.1","port":19334,"label":"local-btxd"}]}
```

Anything else returns `404 {"error":"not_found"}`; non-`GET` methods return
`405 {"error":"method_not_allowed"}`.

## Power use

Mining can draw significant power. Monitor temperature, fan behavior, and power draw with your
vendor tools, and apply any clock or power limits conservatively for your own hardware.

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

This repo builds on other people's hard work. Thanks to:

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
