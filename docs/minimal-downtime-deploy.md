# Minimal-downtime deploys

Version bumps are frequent on this chain (consensus changes every ~1-2 days). Each
restart of the solo node costs a warmup gap - shielded-state load, any one-time state
rebuild, and sync catch-up - during which the GPU is NOT mining. At ~90s block spacing
and our ~0.3-0.4% share, ~10 min of warmup is roughly 7 blocks of lost opportunity.

## Build-then-swap: `make deploy`

The build is the long part (compiling btxd from source, minutes). Docker builds the new
image WITHOUT touching the running container, so `make deploy`:

1. Builds the new `btx-miner` image while the current miner keeps mining.
2. Waits for a clean, well-peered, at-tip window (`scripts/clean-stop.sh`) so the stop
   flushes shielded state cleanly -> ~30s fast-restore next boot instead of a from-genesis
   rebuild. The at-tip check is deterministic (blocks==headers, near-tip peers,
   `reason=healthy`); it deliberately does NOT gate on `initialblockdownload`, which an
   assumeutxo fast-start snapshot keeps `true` while its background validation grinds
   (that false positive once burned the full clean-window timeout before swapping).
3. Swaps (recreates the container on the new image) only after the build succeeds.
4. Polls the solve counter and prints the actual warmup gap (the real downtime). NOTE: the
   counter only moves when the container is GPU-mining - if you run the box node-only
   (mining externally via matador-miner), `make deploy` will report "warming" until its
   timeout even though the node is up; check `make status` / `getnetworkinfo` subversion.

A failed build never takes the miner down, and the only downtime is the warmup, not the
build. Use it for every version bump instead of a manual `up -d --build`:

    # bump BTX_SOURCE_REF in docker-compose.yml first, then:
    make deploy

## Warm standby (gated on the measured warmup)

If `make deploy` shows the warmup gap is painful on EVERY bump (not just a one-time
state rebuild like the 0.32.11 velocity-state cutover), the next lever is a pre-synced,
node-only warm standby:

- Run a second btxd (node-only, no GPU) on a SEPARATE datadir, kept synced and warm.
- On a bump: build the new image, restart the STANDBY on it (it warms in the background
  while the live miner keeps mining), then once the standby is synced+warm, stop the live
  miner (freeing the GPU) and flip the standby into mining mode. It resumes almost
  immediately because its state is already warm. Gap shrinks to ~container start, not the
  full warmup.

Cost: a second datadir (cheap today - the chain is only ~117 MB), a little CPU/network to
keep it synced, and the swap orchestration. NOT built yet on purpose: measure the real
per-bump warmup with `make deploy` first. If normal restarts turn out to be fast (i.e. the
heavy part was only a one-time state rebuild), the standby is unnecessary.
