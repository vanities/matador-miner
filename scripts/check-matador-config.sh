#!/usr/bin/env bash
# check-matador-config.sh — fast tests for standalone matador-miner config support.
#
# This stays Docker/GPU/network-free. The proprietary matador-miner source lives
# under ignored private/, so CI/public clones skip the source-specific assertions;
# local development runs them automatically when the source is present.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

note() { printf '%s\n' "$*" >&2; }
now_ms() {
  if command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
  else
    date +%s000
  fi
}

start_ms=$(now_ms)
note "[check-matador-config] validating config fixtures"
python3 - <<'PY'
import json
from pathlib import Path
expected_backends = {
    'docs/matador-config.example.json': 'cuda',
    'docs/config.example.nvidia.json': 'cuda',
    'docs/config.example.amd.json': 'hip',
    'docs/config.example.mac.json': 'metal',
}
example_payout = 'btx1zcf4z36asua8ylchysphgwfgyfr8267vvznth826epden7lar4fnqvy9gzv'
shibs_pool_url = 'stratum+tcp://stratum.minebtx.com:3333'
required = {'mode', 'pools', 'worker', 'payoutaddress', 'chain', 'backend'}
for path, backend in expected_backends.items():
    p = Path(path)
    data = json.loads(p.read_text())
    missing = sorted(required - set(data))
    assert not missing, f"{p} missing keys: {missing}"
    assert data['mode'] in {'solo', 'pool'}, p
    assert data['backend'] == backend, f"{p} backend={data['backend']} expected {backend}"
    assert data['gpus'] == [0], f"{p}: expected editable single-GPU default"
    assert data['payoutaddress'] == example_payout, f"{p}: expected shared example payout address"
    assert isinstance(data['pools'], list) and data['pools'], f'{p}: pools must be a non-empty list'
    assert data['pools'][0].get('label') == 'shibs-minebtx', f'{p}: first pool should be shibs-minebtx'
    assert data['pools'][0].get('url') == shibs_pool_url, f'{p}: first pool should be shib minebtx stratum'
    for i, pool in enumerate(data['pools']):
        assert isinstance(pool, (str, dict)), f'{p}: pools[{i}] must be string or object'
        if isinstance(pool, dict):
            assert 'url' in pool or ('host' in pool and 'port' in pool), f'{p}: pools[{i}] needs url or host+port'
    assert isinstance(data['overlap'], bool), p
    assert isinstance(data['update_check'], bool), p
    assert isinstance(data['auto_update'], bool), p
    assert isinstance(data['api'], dict), f'{p}: api must be an object'
    assert data['api']['listen'] == '127.0.0.1', p
    assert isinstance(data['api']['port'], int) and data['api']['port'] > 0, p
    assert isinstance(data['watchdog'], dict), f'{p}: watchdog must be an object'
    assert data['watchdog']['enabled'] is True, p
    assert data['watchdog']['check_s'] > 0, p
    assert data['watchdog']['reject_streak'] >= 0, p
    assert data['watchdog']['no_share_s'] >= 0, p
    assert isinstance(data['thermal'], dict), f'{p}: thermal must be an object'
    assert data['thermal']['enabled'] is True, p
    assert data['thermal']['warn_temp_c'] >= 0, p
    assert data['thermal']['critical_temp_c'] >= 0, p
    assert data['thermal']['warn_power_w'] >= 0, p
assert Path('docs/config.example.amd.json').read_text().find('"sidecars"') >= 0
PY

src="private/matador-miner/matador-miner.cpp"
if [ ! -f "$src" ]; then
  note "[check-matador-config] $src absent (private/ ignored) — source assertions skipped"
  elapsed=$(( $(now_ms) - start_ms ))
  note "[check-matador-config] OK in ${elapsed}ms"
  exit 0
fi

hip_patch="private/matador-miner/patches-hip/hip-backend-stub.patch"
if [ ! -f "$hip_patch" ]; then
  echo "missing $hip_patch" >&2
  exit 1
fi
python3 - "$hip_patch" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1]).read_text()
assert 'Kind::HIP' in p
assert 'hip_backend_stub_unimplemented' in p
assert 'normalized == "hip" || normalized == "rocm" || normalized == "amd"' in p
PY
test -x private/matador-miner/build-hip-sidecar.sh || {
  echo "missing executable private/matador-miner/build-hip-sidecar.sh" >&2
  exit 1
}
for build_script in private/matador-miner/build.sh private/matador-miner/build-metal.sh; do
  grep -q 'patches-hip/hip-backend-stub.patch' "$build_script" || {
    echo "$build_script does not apply the HIP backend stub patch" >&2
    exit 1
  }
done

note "[check-matador-config] validating $src"
python3 - <<'PY'
from pathlib import Path
src_path = Path('private/matador-miner/matador-miner.cpp')
s = src_path.read_text()

def expect(name, cond):
    if not cond:
        raise AssertionError(name)

expect('help exposes --config', '--config=<path>' in s)
expect('Config struct records config_path', 'std::string config_path' in s)
expect('default ./matador.json auto config present', 'static std::string AutoConfigPath' in s and 'stat("matador.json"' in s and 'cfg.config_path = AutoConfigPath()' in s)
expect('Config struct records ordered pools', 'std::vector<PoolEndpoint> pools' in s)
expect('LoadConfigFile exists', 'static bool LoadConfigFile' in s)
expect('MATADOR_CONFIG env supported', 'GetEnvOr("MATADOR_CONFIG"' in s)
expect('CLI --config pre-scan supported', 'a.rfind("--config=", 0)' in s and 'a == "--config"' in s)
expect('JSON parser uses UniValue root object', 'root.read(body.str())' in s and 'root.isObject()' in s)
expect('single pool endpoint parsed from config', 'AddPoolEndpointList(cfg, s, /*replace_existing=*/true, "config")' in s)
expect('pools[] parsed from config', 'static bool ConfigPools' in s and 'ConfigValue(obj, {"pools"}' in s)
expect('pool failover loop present', 'failover list endpoints=' in s and 'switching to pool index=' in s)
expect('repeated CLI pools append after clearing lower precedence pools', 'bool cli_pool_seen = false' in s and 'AddPoolEndpointList(cfg, v, /*replace_existing=*/false, "args")' in s)
expect('status API help exposed', '--api-port=<port>' in s and '/health, /summary, /pools' in s)
expect('status API implemented read-only endpoints', 'static std::thread StartStatusApi' in s and 'BuildSummaryJson' in s and 'method != "GET"' in s)
summary_start = s.index('static std::string BuildSummaryJson')
summary_end = s.index('static bool SendAll', summary_start)
expect('status API avoids pool password in summary', 'pool_pass' not in s[summary_start:summary_end])
expect('summary exposes watchdog state', '\\"watchdog\\"' in s and 'last_notify_age_sec' in s and 'reject_streak' in s)
expect('summary exposes GPU runtime telemetry', '\\"gpu_runtime\\"' in s and 'nvidia-smi --query-gpu=uuid,utilization.gpu,power.draw,temperature.gpu' in s)
expect('summary exposes thermal state', '\\"thermal\\"' in s and 'ThermalStatusJson' in s and 'warn_temp_c' in s)
expect('amd telemetry fallback present', 'rocm-smi --showuniqueid --showuse --showpower --showtemp --csv' in s and '\\"vendor\\"' in s)
expect('external hip sidecar path present', 'MATADOR_HIP_SOLVER' in s and 'SolveWithExternalHip' in s and 'btx-gbt-solve-hip' in s)
expect('hip sidecar auto-discovery present', 'ResolveHipSolverPath' in s and 'auto-discovered sidecar=' in s and '--hip-solver=<path>' in s)
expect('hip sidecar config aliases present', '"hip_solver", "hip-solver", "hip_solver_path", "hip-solver-path"' in s and 'root.exists("sidecars") && root["sidecars"].isObject()' in s)
expect('multi-gpu config/cli present', 'std::vector<std::string> gpu_devices' in s and 'static bool ConfigGpuDevices' in s and '--gpus=<ids>' in s and 'MATADOR_GPUS' in s)
expect('multi-gpu process fan-out present', 'static bool MaybeRunMultiGpuSupervisor' in s and 'CUDA_VISIBLE_DEVICES' in s and 'HIP_VISIBLE_DEVICES' in s and 'MATADOR_MULTI_GPU_CHILD_WORKER' in s)
expect('pool watchdog implemented safe reconnect', 'static std::thread StartPoolWatchdog' in s and 'watchdog_reconnect_requested.store(true)' in s and 'actions=reconnect/failover' in s)
expect('thermal watchdog is observe-only', '[thermal] threshold crossed observe_only=true' in s and 'thermal_warn_temp_c' in s)
expect('minebtx shorthand supported', 'if (s == "minebtx") s = "stratum.minebtx.com:3333"' in s)
for key in ['"pool_pass", "pool-pass"', '"payoutaddress", "payout_address"', '"devfee", "dev_fee", "dev-fee"', '"solver_threads", "solver-threads"', '"gpus", "gpu_devices", "gpu-devices", "devices"']:
    expect(f'config alias {key}', key in s)
for key in ['"api_enabled", "api-enabled"', '"api_listen", "api-listen"', '"api_port", "api-port"']:
    expect(f'config alias {key}', key in s)
expect('nested api config supported', 'root.exists("api") && root["api"].isObject()' in s)
for key in ['"watchdog_enabled", "watchdog-enabled"', '"watchdog_check_s", "watchdog-check-s"', '"watchdog_reject_streak", "watchdog-reject-streak"', '"watchdog_no_share_s", "watchdog-no-share-s"']:
    expect(f'config alias {key}', key in s)
expect('nested watchdog config supported', 'root.exists("watchdog") && root["watchdog"].isObject()' in s)
for key in ['"thermal_enabled", "thermal-enabled"', '"thermal_warn_temp_c", "thermal-warn-temp-c"', '"thermal_critical_temp_c", "thermal-critical-temp-c"', '"thermal_warn_power_w", "thermal-warn-power-w"']:
    expect(f'config alias {key}', key in s)
expect('nested thermal config supported', 'root.exists("thermal") && root["thermal"].isObject()' in s)

# Precedence is the user-visible contract: defaults < config < env < CLI.
idx_config_path = s.index('cfg.config_path = AutoConfigPath()')
idx_env_config = s.index('GetEnvOr("MATADOR_CONFIG"')
idx_help_prescan = s.index('if (a == "--help" || a == "-h") { PrintHelp(); std::exit(0); }', idx_config_path)
idx_load = s.index('LoadConfigFile(cfg.config_path, cfg)')
idx_env = s.index('// env fallbacks override config-file values')
idx_cli = s.index('for (; i < argc; ++i)')
expect('precedence order defaults<autoconfig<env<cli', idx_config_path < idx_env_config < idx_load < idx_env < idx_cli)
expect('help exits before config load', idx_config_path < idx_help_prescan < idx_load)

# Secrets may be read, but the config loader should only log file/shape/counts.
loader_start = s.index('static bool LoadConfigFile')
loader_end = s.index('// ASCII splash', loader_start)
loader = s[loader_start:loader_end]
for forbidden in ['cfg.rpcpassword <<', 'cfg.pool_pass <<', 'rpcpassword="', 'pool_pass="']:
    expect(f'secret not logged via {forbidden}', forbidden not in loader)
PY

elapsed=$(( $(now_ms) - start_ms ))
note "[check-matador-config] OK in ${elapsed}ms"
