# btx-miner — isolated GPU solo-miner for `btxchain/btx`

A Docker setup to point an idle NVIDIA GPU (e.g. an RTX 5090) at the
`btxchain/btx` chain and see whether it can mine a block while keeping the node,
miner, and wallet data isolated from the host.

> **Upstream / official node:** [`github.com/btxchain/btx`](https://github.com/btxchain/btx). Pinned to commit [`2da3b17`](https://github.com/btxchain/btx/commit/2da3b1754d35ae157229f878a858f169a8061d28) (**0.30.2**, `main` HEAD as of 2026-06-01). Upstream bumped to 0.30.2 but has not yet cut a `v0.30.2` tag or a GPG-signed precompiled release, so this repo **compiles that exact commit from source** with the CUDA MatMul backend. When the signed v0.30.2 archives land, switch back to the precompiled path: set `BTX_INSTALL_MODE=release` + `RELEASE_TAG=v0.30.2` in `docker-compose.yml`.

## What this does

- Compiles `btxd` + `btx-cli` and the CUDA MatMul backend from a pinned upstream commit (0.30.2), in the Docker build.
- Runs that BTX full node in Docker.
- Creates/uses a local wallet under `./btx-data`.
- Starts a supervised GPU solo-mining loop using BTX's MatMul proof-of-work.

## Safety model (why this is the contained way to try it)

- Runs entirely in a container; the node/miner cannot see your host filesystem.
- **Source build:** compiles a single, pinned, immutable commit from
  [`github.com/btxchain/btx`](https://github.com/btxchain/btx). This trades the
  GPG signature of a precompiled release for commit pinning. It is acceptable
  **only** because everything runs sandboxed here with no funds at stake; do not
  extend trust beyond this container. Set `BTX_INSTALL_MODE=release` to go back
  to running only the GPG-signed release once 0.30.2 is signed.
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

First build **compiles btxd + the CUDA backend from source** (a one-time
~20-40 min step; the NVIDIA CUDA toolchain it needs is pulled into the Docker
build, not your host). After that it syncs the chain (fast-start / assumeutxo
keeps this short), prints **your** mining address, and starts a supervised
solo-mining loop. Rebuilds reuse Docker's layer cache, so nothing recompiles
unless you change `BTX_SOURCE_REF`.

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
To switch back to the signed precompiled release once 0.30.2 is tagged + signed,
set `BTX_INSTALL_MODE=release` and `RELEASE_TAG=v0.30.2`; the entrypoint then
runs the upstream `faststart` installer (see `doc/linux-release-builds.md`).

## Power use

A 5090 mining full-tilt draws ~0.5 kW → roughly **$1–2/day** in electricity.

## License

[GNU General Public License v3.0](LICENSE)
