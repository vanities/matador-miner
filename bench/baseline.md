# btx-miner — GPU bench baseline

MatMul-PoW solver throughput measured with the bundled
`btx-matmul-solve-bench`, miner paused so the runs are uncontended.

- **GPU:** NVIDIA RTX 5090 (Blackwell, CUDA 13)
- **Algo params:** `n=512, b=16, r=8` (mainnet), `--backend cuda`, `--iterations 100`
- **Date:** 2026-05-22
- **Metric:** `nonces_per_sec` — MatMul nonce attempts per second (this algo's "hashrate")

| Power limit | Hashrate (median) | Hashrate (mean) | ms/iter (median) | Efficiency (nonces/s per W) |
|-------------|-------------------|-----------------|------------------|-----------------------------|
| 575 W (default) | 133,455 /s    | 132,471 /s      | 15.3 ms          | ~232                        |
| 460 W (80%)     | 120,949 /s    | 121,375 /s      | 16.9 ms          | ~263 (~282 vs ~429 W actual draw) |

**Delta at 80% power:** hashrate −9.4%, power −20% (limit, ~−25% actual draw)
→ **efficiency +~13%** (≈ +21% measured against actual draw).

**Conclusion:** 460 W (80%) is the efficiency sweet spot — the standard
power-limit play (same as the ETH-era ~80% rule). You give up ~9% hashrate to
save 20%+ power. Apply with `sudo nvidia-smi -pl 460` (revert: `-pl 575`).

> Reminder: hashrate has zero bearing on profitability here — BTX has no market.
> This is pure efficiency tuning of the rig, not an earnings lever.

## Power-efficiency research (RTX 5090, general GEMM/compute)

The PoW is dense matrix multiplication, so general 5090 GEMM/AI-compute
efficiency findings transfer directly. Community consensus:

- The 5090 ships **pushed past its efficiency knee** — NVIDIA set TDP to 575 W
  for peak performance, so stock perf/watt is actually ~5% *worse* than the
  4090 in gaming. The top ~100 W buys very little.
- An aggressive undervolt held **~99% of stock performance at ~464 W** (−16%
  power): ~80% power ≈ ~99% perf for general compute.
- **Sweet spot: ~70–85% power (≈400–490 W).** Below ~400 W real performance
  drops; above ~490 W you mostly waste watts.

### Caveat: power-limit vs undervolt

`nvidia-smi -pl` caps watts and lets clocks drop reactively — less efficient
than a true undervolt (lower voltage at the same clocks). That's why our
measured `-pl 460` lost ~9% (vs ~1% for a real undervolt), compounded by matmul
saturating the compute units harder than gaming does. On Linux, approximate a
true undervolt by locking clocks alongside the limit, e.g.
`sudo nvidia-smi -lgc 0,2400` (tune the max) plus `sudo nvidia-smi -pl 460`.

### Bottom line

460 W (80%) is the well-supported pick. To find the exact matmul knee, run
`sudo bash bench/sweep.sh` (sweeps to the 400 W floor); for pure GEMM the
optimum may sit a bit above 400 W (~440–490). This only tunes electricity
cost — it doesn't change that BTX has no market.

Sources:
- [RTX 5090 ~99% perf at 464 W via undervolt — SlashGear](https://www.slashgear.com/1902896/rtx-5090-how-much-power-can-pull-nvidia-geforce-gpu/)
- [RTX 5090 perf/watt ~5% below 4090 — TechSpot](https://www.techspot.com/review/2944-nvidia-geforce-rtx-5090/)
- [RTX 5090 power & efficiency analysis — Overclocking.com](https://en.overclocking.com/review-nvidia-rtx-5090-founders-edition/12/)
