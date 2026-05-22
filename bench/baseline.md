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
