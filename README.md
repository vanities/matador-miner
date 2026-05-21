# btx-miner — isolated GPU solo-miner for `btxchain/btx`

A throwaway Docker setup to point an idle NVIDIA GPU (e.g. an RTX 5090) at the
`btxchain/btx` chain and see whether it can mine a block — **without** exposing
your real machine, wallet, or money.

## Read this first — what this does and does NOT prove

- ✅ It proves your GPU can run BTX's MatMul proof-of-work and, *if network
  difficulty is low enough*, find a block worth 20 BTX.
- ❌ It proves **nothing** about whether those BTX are worth money. BTX is not
  listed on any independent exchange; every dollar figure on `btxprice.com` is a
  price the project sets for itself. Coins in your wallet are only worth what a
  **stranger, on a venue the project does not control,** will actually pay.

**The one test that settles value:** after you've mined some BTX, send ~$50
worth to someone for real money on an exchange `btxchain` does not operate. If
you can't, the "value" was never real — but the electricity you spent was.

## Safety model (why this is the contained way to try it)

- Runs entirely in a container; the node/miner cannot see your host filesystem.
- Installs **only** the GPG-signed release from `github.com/btxchain/btx` (via the
  project's own `faststart` installer). It never downloads or runs anything from
  `btxprice.com` or a DM link — that is the actual malware vector.
- Mines to a wallet generated **inside your mounted `./btx-data`** — *you* hold
  the keys (self-custody), not the website.
- Publishes no ports and requires **$0**. No deposit, no "activation," no "fee to
  withdraw." If anything ever asks for that, it's a scam — stop.

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

## Cost

A 5090 mining full-tilt draws ~0.5 kW → roughly **$1–2/day** in electricity.
That is the real, guaranteed cost. Everything else is a bet on a six-week-old
coin whose only price is quoted by the people who made it.
