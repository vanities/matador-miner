# matador fleet - solo mining through one coordinator

This is the "local archive node + hop-on/hop-off" appliance: the stateful, uptime-bearing
parts (the `btxd` archive node and the chain) live on **one coordinator host**; every other
machine is a **disposable, stateless solver** that mines through it. A worker can join for
20 minutes between jobs and contribute with **zero warmup**, because it carries no chain
state.

```
                 COORDINATOR HOST (long uptime)
                 +------------------------------------------+
                 |  btxd  (archive/full node)               |
                 |    | RPC (cookie)                         |
                 |    v                                      |
                 |  matador-gbt-proxy  :4071  (this repo)    |  least-privilege:
                 |    - basic-auth: password = FLEET_TOKEN   |  ONLY getblocktemplate
                 |    - forwards getblocktemplate/submitblock|  + submitblock; refuses
                 |    - refuses every other RPC method       |  wallet/stop/etc
                 |                                           |
                 |  matador-hub        :4070  (telemetry)    |  /fleet + dashboard
                 +-------------------+----------------------+
                    LAN / VPN        |   (never public; token + firewall)
        +-------------+--------------+--------------+
        v             v                             v
   +---------+   +---------+                   +---------+
   | worker  |   | worker  |     ...           | worker  |   matador-miner --mode solo
   | (no node)|  | (no node)|                  | (no node)|   --rpcconnect coordinator
   +---------+   +---------+                   +---------+   --rpcport 4071
   all pay ONE fleet wallet; a per-rig coinbase extranonce keeps their work disjoint
```

## Why single wallet + extranonce (what real operators do)

Large solo farms and pools both mine to a **single on-chain address** - it's all one
owner's money (farm), or miners are credited off-chain via shares (pool). They avoid two
rigs grinding the *same* work not with separate addresses but with a **coinbase
extranonce**: a distinct extranonce -> distinct coinbase -> distinct merkle root ->
disjoint search space. That's exactly how Stratum partitions work across connections.

matador does the same for solo-via-proxy: each worker stamps its **`--worker` name + 4
random bytes** into the coinbase scriptSig. So a whole fleet shares one `--payoutaddress`
and still gets full N x hashrate with **no duplicate work**, and you can read which rig
mined a block from its coinbase. Give every rig a **unique `--worker`** (the random bytes
are a backstop if two ever collide).

## Coordinator setup

You need a synced `btxd` (this repo's `make node`/`make solo`, or any `btxd` v0.32.12+ with
RPC enabled) and the proxy. The proxy authenticates workers by a shared **fleet token**
(presented as the basic-auth password) and talks to `btxd` with its cookie:

```bash
# pick a strong shared token once
export FLEET_TOKEN="$(head -c 24 /dev/urandom | base64)"

python3 scripts/matador-gbt-proxy.py \
  --listen 0.0.0.0 --port 4071 \          # LAN/VPN bind - firewall it; token is the gate
  --node-url http://127.0.0.1:19334/ \
  --node-cookie ~/.btx/.cookie \          # or --node-rpcuser/--node-rpcpassword
  --token "$FLEET_TOKEN"

# fleet telemetry (optional but recommended) - see docs/matador-hub.md
python3 scripts/matador-hub.py --worker rig1=http://10.0.0.11:4060 ... --port 4070
```

The proxy exposes only `getblocktemplate` + `submitblock`; `GET /stats` shows forwarded vs
refused counts, `GET /health` is a liveness check. It never exposes wallet, `stop`, peer,
or key RPCs, so a worker (or a compromised one) cannot touch the node beyond pulling work
and submitting solved blocks.

## Worker setup

A worker needs **no node and no code change** - matador's solo RPC client already speaks
the JSON-RPC the proxy accepts. Point it at the coordinator, present the token as the RPC
password, set the shared fleet payout, and give it a unique worker name:

```bash
matador-miner --mode solo \
  --rpcconnect coordinator.lan --rpcport 4071 \
  --rpcuser rig7 --rpcpassword "$FLEET_TOKEN" \   # username = log label; password = token
  --payoutaddress btx1...FLEET_WALLET \           # ONE shared wallet for the whole fleet
  --worker rig7 \                                 # unique per rig -> coinbase extranonce
  --api --api-port 4060                           # so the hub can see it
```

Config-file form (`matador.json`):

```json
{
  "mode": "solo",
  "rpcconnect": "coordinator.lan",
  "rpcport": 4071,
  "rpcuser": "rig7",
  "rpcpassword": "<FLEET_TOKEN>",
  "payoutaddress": "btx1...FLEET_WALLET",
  "worker": "rig7",
  "backend": "cuda",
  "api": { "enabled": true, "listen": "0.0.0.0", "port": 4060 }
}
```

Hopping on = start the worker; hopping off = stop it. No warmup either way - the
coordinator holds the chain. When a worker solves, it submits through the proxy and the
coordinator's well-peered node broadcasts, so the disposable workers don't need good
peering (this also reduces orphans vs every rig broadcasting independently).

## Resilience: automatic pool fallback

The coordinator is a single point of failure for the fleet's solo mining, so a worker can
fall back to a pool when it goes down and return to solo when it recovers - no idle rigs:

```bash
matador-miner --mode solo \
  --rpcconnect coordinator.lan --rpcport 4071 --rpcuser rig7 --rpcpassword "$FLEET_TOKEN" \
  --payoutaddress btx1...FLEET_WALLET --worker rig7 \
  --fallback-pool stratum+tcp://stratum.minebtx.com:3333 \  # where to mine if the coordinator dies
  --fallback-after-s 60 \                                   # solo down this long -> fail over
  --solo-recheck-s 120                                      # while on pool, probe coordinator this often
```

If the coordinator's GBT source is unreachable for `--fallback-after-s`, the worker
re-exec's (same PID) into pool mode on `--fallback-pool`; a recovery prober then checks the
coordinator every `--solo-recheck-s` and re-exec's back to solo once it answers. Config
keys: `fallback_pool`, `fallback_after_s`, `solo_recheck_s` (env `MATADOR_FALLBACK_POOL`
etc). Leave `fallback_pool` empty to disable (solo just retries forever, the old behavior).

## Idle-gate: mine when the box is idle, yield when it's needed

This is the literal "hop on / hop off" - let a workstation or a datacenter node mine in
its spare cycles and **instantly give the GPU back** when real work shows up. matador polls
an operator-supplied command and pauses when it says to:

```bash
matador-miner --mode solo --rpcconnect coordinator.lan --rpcport 4071 \
  --rpcuser rig7 --rpcpassword "$FLEET_TOKEN" --payoutaddress btx1...FLEET_WALLET --worker rig7 \
  --should-mine-command "/opt/matador/scripts/gpu-idle.sh 5" \  # exit 0=mine, non-zero=yield
  --should-mine-interval 2 \                                    # poll cadence (s)
  --gate-yield abort                                            # kill in-flight solve to free GPU fast
```

- **Polarity** (matches the node's `test ! -f .pause-mining` convention): the command
  exits **0 = mine**, **non-zero = yield**. Empty = always mine.
- On yield with `--gate-yield abort` (default), matador aborts the in-flight solve so the
  GPU frees within ~the poll interval; `finish` lets the current solve complete first.
- No warmup on resume - the coordinator holds the chain.
- The gated state is visible: `/summary` reports `mining_state` (`mining`|`gated`) and
  `gate_reason` (the command's stdout), and the hub shows a **gated** category.

**Reference gate `scripts/gpu-idle.sh <idle_min> [gpu] [self_match]`:** mine only when no
*other* GPU compute process is running (it excludes matador itself), after the GPU has been
free for `idle_min` minutes. It keys off **foreign GPU processes, not raw utilization** -
because while matador mines the GPU is at ~99%, a util-threshold gate would fight its own
load and flap. For desktop/gaming yield (a game may use a graphics context, not a compute
one), gate on a session/activity check instead - the command can be anything.

The poll is cheap and **off the GPU**: it spawns a single-field `nvidia-smi` query every
couple seconds on a background thread (the same class of call matador's thermal watchdog
already makes), so it does not touch mining throughput - the only cost is the intended one
(yielding when the box is busy).

## Security notes

- **Bind the proxy and hub to LAN/VPN only** and firewall them. The fleet token is the only
  gate; treat it like a password and rotate it by restarting the proxy with a new `--token`.
- The proxy is **least-privilege by construction** - the method whitelist is hard-coded to
  `getblocktemplate` + `submitblock`. Even a fully compromised worker cannot drain a wallet
  or stop the node through it.
- The proxy is a single point of failure for the fleet's solo mining; workers handle this
  with automatic pool fallback (see above) so a coordinator outage doesn't idle rigs.

## See also

- `docs/matador-hub.md` - fleet telemetry aggregator (phase 1)
- `docs/matador-standalone-ops.md` - single-rig ops, auto-update, systemd
- `scripts/matador-gbt-proxy.py --help`, `scripts/matador-hub.py --help`
