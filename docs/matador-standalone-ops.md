# matador-miner standalone operations

This is the first farm-operator layer for the standalone `matador-miner` binary: a stable JSON config file, a systemd service shape, and the next seams for ETH-era miner polish.

## Config file

`matador-miner` automatically loads `./matador.json` when it exists. It also accepts `--config <path>` or `MATADOR_CONFIG=<path>`. Precedence is:

```text
defaults < JSON config < environment variables < CLI flags
```

That means a bundle can be run by copying one hardware template to `matador.json`, while a rig can still keep durable settings in `/etc/matador-miner/config.json`, put secrets in a protected env file if desired, and override one setting for a one-off run.

Example pool config:

```bash
cp config.example.nvidia.json matador.json   # NVIDIA/CUDA
# cp config.example.amd.json matador.json    # AMD/ROCm sidecar
# cp config.example.mac.json matador.json    # Apple Silicon/Metal
$EDITOR matador.json                         # set your real P2MR payout address
./bin/matador-miner                          # auto-loads ./matador.json
```

The source tree also keeps these templates under `docs/` for packagers: `config.example.nvidia.json`, `config.example.amd.json`, and `config.example.mac.json`.

Supported JSON keys mirror the existing CLI/env surface:

- `mode`: `solo` or `pool`
- `pool`: `host:port`, `stratum+tcp://host:port`, or a comma-separated failover list for pool mode
- `pools`: ordered failover array. Entries may be strings (`"minebtx.com:3333"`) or objects with either `url` or `host`+`port` plus optional `label`/`name`. The first entry is primary; later entries are tried when connect/disconnect/stall recovery trips.
- `worker`, `pool_pass`
- `chain`, `backend` (`cuda`, `metal`, `cpu`, or `hip`/`rocm`). HIP/ROCm delegates solves to the external C++/HIP `btx-gbt-solve-hip` sidecar. Release bundles auto-discover it next to `bin/matador-miner`; outside a bundle use `--hip-solver <path>` or config `sidecars.hip`.
- `api`: optional local read-only status API object: `{ "enabled": true, "listen": "127.0.0.1", "port": 4060 }`
- `api_enabled` / `api_listen` / `api_port`: flat aliases for the same status API settings
- `watchdog`: pool-mode self-supervision object: `{ "enabled": true, "check_s": 15, "reject_streak": 20, "no_share_s": 0 }`
- `watchdog_enabled`, `watchdog_check_s`, `watchdog_reject_streak`, `watchdog_no_share_s`: flat aliases. `no_share_s: 0` leaves the accepted-share timeout observe-only/off by default.
- `thermal`: warning-only GPU temp/power object: `{ "enabled": true, "warn_temp_c": 86, "critical_temp_c": 90, "warn_power_w": 0 }`. This only logs/API-reports thresholds; it does not change clocks, fans, power limits, or restart the process.
- `thermal_enabled`, `thermal_warn_temp_c`, `thermal_critical_temp_c`, `thermal_warn_power_w`: flat aliases for the same thermal settings.
- `payoutaddress` / `payout_address`
- `rpcconnect`, `rpcport`, `datadir`, `rpccookiefile` / `rpc_cookie_file`, `rpcuser`, `rpcpassword`
- `maxtries` / `max_tries`
- `devfee` / `dev_fee`, `devaddress` / `dev_address`
- `solver_threads`, `overlap`
- `update_check`, `auto_update`

Do not commit a real config if it contains RPC credentials. The miner logs the config file path, byte size, and number of applied settings, but not RPC passwords or pool passwords.

## Local status API

Enable the read-only HTTP API for dashboards/watchdogs:

```bash
matador-miner --config /etc/matador-miner/config.json --api --api-port 4060
curl -s http://127.0.0.1:4060/health
curl -s http://127.0.0.1:4060/summary
curl -s http://127.0.0.1:4060/pools
```

The API binds to `127.0.0.1` by default. Keep it loopback-only unless a LAN firewall is intentionally protecting it. It exposes runtime counters, backend, worker, chain, public payout address, pool endpoints, and watchdog state; it does **not** expose RPC credentials or pool passwords.

`/summary` includes:

- `gpu_runtime`: best-effort GPU telemetry array with `gpu_uuid`, `vendor`, `util_pct`, `power_w`, and `temp_c`. NVIDIA uses `nvidia-smi`; AMD falls back to `rocm-smi` CSV when no NVIDIA rows are present (`[]` when unavailable, such as macOS/CPU-only hosts)
- `thermal`: warning-only status derived from the same GPU telemetry (`ok`, `warning`, `critical`, `disabled`, or `unavailable`)
- `watchdog.status`: `ok`, `warning`, or `disabled`
- `watchdog.reject_streak`
- `watchdog.last_notify_age_sec`, `last_share_age_sec`, `last_accept_age_sec`, `last_nonce_age_sec`
- `watchdog.last_warning`, `last_action`, and `reconnect_requested`

The first action set is deliberately safe: in pool mode the watchdog can request a reconnect/failover, which uses the same disconnect/reconnect path as normal pool loss. It does **not** restart the process, change clocks/fans, or touch power limits.

For a quick terminal dashboard once the API is enabled:

```bash
scripts/matador-status.sh
# or: MATADOR_API_URL=http://127.0.0.1:4060/summary scripts/matador-status.sh
```

CLI/env failover forms are also supported:

```bash
# repeat --pool; CLI clears lower-precedence config/env pools then appends each flag
matador-miner --mode pool --pool stratum+tcp://stratum.minebtx.com:3333 \
  --payoutaddress btx1zcf4z36asua8ylchysphgwfgyfr8267vvznth826epden7lar4fnqvy9gzv --worker rig1

# or comma-separate POOL / JSON `pool`
POOL=stratum+tcp://stratum.minebtx.com:3333 matador-miner --mode pool \
  --payoutaddress btx1zcf4z36asua8ylchysphgwfgyfr8267vvznth826epden7lar4fnqvy9gzv --worker rig1
```

## systemd service template

For a standalone pool rig:

```ini
# /etc/systemd/system/matador-miner.service
[Unit]
Description=Matador BTX standalone miner
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=miner
Group=miner
Environment=LOG_LEVEL=info
Environment=MATADOR_CONFIG=/etc/matador-miner/config.json
ExecStart=/usr/local/bin/matador-miner
Restart=always
RestartSec=10
TimeoutStopSec=30
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
```

Install/start:

```bash
sudo useradd --system --create-home --shell /usr/sbin/nologin miner || true
sudo systemctl daemon-reload
sudo systemctl enable --now matador-miner.service
journalctl -u matador-miner -f
```

For solo mode, either point `rpccookiefile` at a readable cookie or run the service as a user that can read the local `btxd` datadir cookie.

## Next operator-polish seams

Config files create a stable interface for the next ETH-era features:

1. **Temperature / backend-stall watchdogs**: expose GPU temp/power and detect nonce-counter stalls; keep the first version observe/reconnect-only.
2. **Thermal/power controls**: move the current external `gpu-tune.service` settings behind explicit per-GPU config keys.
3. **True multi-GPU**: add `devices[]` plus per-device counters; the config file gives us somewhere clean to persist those choices.
