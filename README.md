# btx-miner — isolated GPU solo-miner for `btxchain/btx`

A Docker setup to point an idle NVIDIA GPU (e.g. an RTX 5090) at the
`btxchain/btx` chain and see whether it can mine a block while keeping the node,
miner, and wallet data isolated from the host.

> **Upstream / official node:** [`github.com/btxchain/btx`](https://github.com/btxchain/btx). Pinned to the **v0.32.2** tag commit [`341781d`](https://github.com/btxchain/btx/commit/341781da970b99723e60c88580774a10167ff77e). Upstream now ships a GPG-signed `cuda13` prebuilt, but this repo **compiles that exact commit from source** with the CUDA MatMul backend by choice — it guarantees native `sm_120` codegen for the 5090 and a byte-reproducible build (the release signing key is integrity-only, so commit-pinning is comparable trust). To run the signed prebuilt instead, set `BTX_INSTALL_MODE=release` + `RELEASE_TAG=v0.32.2` in `docker-compose.yml`. **0.32.2 carries a mandatory network upgrade at block 125,000 (shielded sunset + MatMul nonce-seed v2) — older versions fork off the network after that height.**

## What this does

- Compiles `btxd` + `btx-cli` and the CUDA MatMul backend from a pinned upstream commit (0.32.2), in the Docker build.
- Runs that BTX full node in Docker.
- Creates/uses a local wallet under `./btx-data`.
- Starts a supervised GPU solo-mining loop using BTX's MatMul proof-of-work.

## Safety model (why this is the contained way to try it)

- Runs entirely in a container; the node/miner cannot see your host filesystem.
- **Source build:** compiles a single, pinned, immutable commit from
  [`github.com/btxchain/btx`](https://github.com/btxchain/btx). The signed
  release key is integrity-only (self-published, no independent vouching), so
  commit pinning is comparable trust — and a native `sm_120` compile is better
  for the 5090. Acceptable **only** because everything runs sandboxed here with
  no funds at stake; do not extend trust beyond this container. Set
  `BTX_INSTALL_MODE=release` to run the signed prebuilt instead.
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

### Solo vs pool

By default this **solo-mines** with our patched node solver (fastest path —
you keep 100% of every block you find). You can instead mine to the
**[minebtx / DEXBTX pool](https://minebtx.com)** for steady payouts:

```bash
make pool     # switch to pool mining (stops solo; payout address from address.txt)
make solo     # switch back to solo
make pool-logs
```

Trade-off: pool mode runs the pool's own `btx-gbt-solve` (BTX v0.32.5,
SHA256-verified at build). As of that build the pool **adopted our PR#58 GPU
kernel optimizations**, so it's now roughly comparable to our solo solver rather
than the ~3× sacrifice the old 0.32.2 build was — pool mode now trades just the
2.5% fee for steady weekly PPLNS payouts instead of solo's all-or-nothing block
lottery. Solo and pool can't run at once (one GPU), so the targets stop one
before starting the other. The pool client runs in its own container with **no
wallet/chain mount** — payouts go to your public `btx1z...` address, no keys are
exposed.

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
To run the signed precompiled release instead, set `BTX_INSTALL_MODE=release`
and `RELEASE_TAG=v0.32.2`; the entrypoint then runs the upstream `faststart`
installer (see `doc/linux-release-builds.md`).

## Power use

A 5090 mining full-tilt draws ~0.5 kW → roughly **$1–2/day** in electricity.

## License

[GNU General Public License v3.0](LICENSE)
