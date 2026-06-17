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

## Security notes

- **Bind the proxy and hub to LAN/VPN only** and firewall them. The fleet token is the only
  gate; treat it like a password and rotate it by restarting the proxy with a new `--token`.
- The proxy is **least-privilege by construction** - the method whitelist is hard-coded to
  `getblocktemplate` + `submitblock`. Even a fully compromised worker cannot drain a wallet
  or stop the node through it.
- The proxy is a single point of failure for the fleet's solo mining; pool fallback on the
  worker (so a coordinator outage doesn't idle rigs) is the next planned piece.

## See also

- `docs/matador-hub.md` - fleet telemetry aggregator (phase 1)
- `docs/matador-standalone-ops.md` - single-rig ops, auto-update, systemd
- `scripts/matador-gbt-proxy.py --help`, `scripts/matador-hub.py --help`
