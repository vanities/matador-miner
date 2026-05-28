# btx-miner — isolated GPU solo-miner for `btxchain/btx`

A Docker setup to point an idle NVIDIA GPU (e.g. an RTX 5090) at the
`btxchain/btx` chain and see whether it can mine a block while keeping the node,
miner, and wallet data isolated from the host.

> **Upstream / official node:** [`github.com/btxchain/btx`](https://github.com/btxchain/btx) — pinned to release **`v0.30.1`** (the latest as of 2026-05-21). This repo builds nothing of its own; it only downloads and verifies that project's GPG-signed release.

## What this does

- Runs a BTX full node in Docker.
- Downloads and verifies the upstream GPG-signed release.
- Creates/uses a local wallet under `./btx-data`.
- Starts a supervised GPU solo-mining loop using BTX's MatMul proof-of-work.

## Safety model (why this is the contained way to try it)

- Runs entirely in a container; the node/miner cannot see your host filesystem.
- Installs **only** the GPG-signed release from [`github.com/btxchain/btx`](https://github.com/btxchain/btx) (via the
  project's own `faststart` installer).
- Mines to a wallet generated **inside your mounted `./btx-data`** so the wallet
  state and keys persist outside the container.
- Publishes no ports and does not require any external wallet service.

## Prerequisites (on the Linux box with the GPU)

- Docker + Docker Compose v2
- Recent NVIDIA driver (CUDA 13 / Blackwell RTX 5090 needs R580+)
- `nvidia-container-toolkit` installed and configured:
  `sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker`
- Confirm the GPU is visible to Docker:
  `docker run --rm --gpus all nvidia/cuda:13.0.0-runtime-ubuntu24.04 nvidia-smi`

## Run

```bash
# copy this folder to the Linux box, then:
docker compose up --build
```

Or use the **Makefile** (on the Linux box): `make up` / `down` / `logs` /
`status` / `balance` / `backup` / `restore` — run `make help` for the full list.

First run downloads + verifies the signed release and syncs the chain
(fast-start / assumeutxo keeps this short), then prints **your** mining address
and starts a supervised solo-mining loop.

## Monitor

```bash
docker compose logs -f
docker compose exec btx-miner btx-cli -datadir=/data getblockchaininfo            # sync state
docker compose exec btx-miner btx-cli -datadir=/data getmininginfo                # difficulty, chain_guard
docker compose exec btx-miner btx-cli -datadir=/data -rpcwallet=miner getbalance  # what you've mined
cat ./btx-data/miner-address.txt                                                  # your reward address
```

## Stop / clean up

```bash
docker compose down        # stop
rm -rf ./btx-data          # delete chain data + wallet (back it up first if you mined anything)
```

## Manual fallback (if the automated path hiccups)

The image is just the project's own tooling, so you can run the documented steps
by hand:

```bash
docker compose run --rm --entrypoint bash btx-miner
# inside the container:
python3 /opt/btx-src/contrib/faststart/btx-agent-setup.py \
  --repo btxchain/btx --release-tag v0.30.1 --preset miner --datadir=/data
BTX_MATMUL_BACKEND=cuda /data/bin/btxd -datadir=/data -server=1 -daemon
/data/bin/btx-cli -datadir=/data createwallet miner
/data/bin/btx-cli -datadir=/data -rpcwallet=miner getnewaddress
/opt/btx-src/contrib/mining/start-live-mining.sh \
  --datadir=/data --wallet=miner \
  --address-file=/data/miner-address.txt --should-mine-command=/bin/true
```

Exact binary paths/flags come from the upstream README and
`doc/linux-release-builds.md`; adjust if they've changed since `v0.30.1`.

## Power use

A 5090 mining full-tilt draws ~0.5 kW → roughly **$1–2/day** in electricity.
