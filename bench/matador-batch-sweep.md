# MATADOR BTX Miner: --batch Size Sweep (RTX 5090)

Goal: find the optimal `--batch` (CUDA nonces per kernel launch) for the MATADOR
NVIDIA miner on the RTX 5090. Prior benchmarking showed batch size is the dominant
throughput lever (0.2.32 auto-picks 2626; 0.2.33's auto-picker clamps to 1024).
Batch is a launch-config knob only, not consensus-critical, so it was swept freely.

## TL;DR

- Recommended: **`BTX_BATCH=32768`** (`--batch 32768`).
- Gain vs the 0.2.32 auto baseline (batch=2626): **+107%** per-slice throughput
  (6.58M -> 13.60M nonces/s).
- Gain vs 0.2.33's auto-clamped batch=1024: even larger (1024 sits well below 2626
  on the steep part of the curve; not separately benchmarked, but strictly worse
  than 2626, so the real-world uplift over a stock 0.2.33 install is **>2x**).
- Peak throughput is at batch=65536 (+115%), but it beats 32768 by only +4.0% while
  drawing +35W. 32768 is +3.5% better on nonces/watt, which is the rig's stated
  optimization target, so 32768 is the pick. Use 65536 if you want absolute peak
  raw rate and do not care about the extra watts.
- The sweep is bounded by **GPU occupancy / compute, NOT VRAM**. Peak VRAM was
  ~6.95 GB of a 32 GB card (~21%); the miner itself only ever held ~2.56 GB above
  the resident-python baseline. There was no CUDA OOM, allocation failure, or
  instability at any batch up to 131072.

## Methodology

| Item | Value |
|------|-------|
| GPU | NVIDIA GeForce RTX 5090 (32607 MiB, power limit 575 W, stock) |
| Driver | 595.71.05 |
| CUDA toolkit (build) | 12.8.0 (nvidia/cuda:12.8.0-devel-ubuntu24.04) |
| CUDA arch | sm_120 (`-DCMAKE_CUDA_ARCHITECTURES=120`) |
| Binary | btx-nvidia-miner v0.2.33 base (commit 9a7e50e) + windowed-SHA matrixgen patch |
| Patch | /tmp/windowed-sha-matrixgen.patch (md5 00038896cd98ee830f507096999044df), 65 midstate refs in src/cuda/gpu_sha256.cu |
| Build type | Release, `-DBTX_MINER_ENABLE_CUDA=ON` |
| Workload | live pool: stratum+tcp://stratum.minebtx.com:3333, worker `<addr>.BATCHTEST`, `--dev-fee 0` |
| Slice / cap | defaults (5s slices, 20M-nonce intensity cap), `--devices all` |
| Run length | ~70s per batch (first ~8s discarded for kernel warm-up); 12-27 measured slices each |
| GPU contention | none. Live miner (`btx-pool-nv`) was stopped for the duration; single resident host `python` held a fixed 4390 MiB VRAM baseline |
| Sampling | nvidia-smi util / power / mem polled every 2s across the window; medians reported |

### On the 0.2.32 vs 0.2.33 base

The dev clone `~/nvminer-dev` is v0.2.33 (commit 9a7e50e); the requested 0.2.32 base
(df4e50e) is not reachable from the upstream remote (only the `v0.2.33` tag and
`main` exist), so the exact 0.2.32 tree could not be reconstructed. This does not
affect the sweep: the "0.2.33 clamps to 1024" behavior lives only inside the
**auto** batch picker (`AutoBatchSizeForDevice`: `batch = std::max(1024, batch)`
then `std::min(batch, cap)` in src/cuda/cuda_solver.cpp). An explicit `--batch <N>`
is returned **verbatim** by `ResolveLaunchBatch` with no clamp, cap, or min, on both
versions. This was verified directly with `--print-gpu-batch`:

```
--batch 2626   -> launch batch=2626
--batch 8192   -> launch batch=8192
--batch 16384  -> launch batch=16384
--batch 262144 -> launch batch=262144
```

So an explicit-batch sweep on the 0.2.33+patch binary transfers 1:1 to a
0.2.32+patch binary. The throughput-relevant code (the windowed-SHA matrixgen
patch) is byte-identical between the two.

### Metric note

"Per-slice N/s" is the truer raw rate (each `slice done ... <rate> nonces/s` log
line) and is the primary metric below; the **median** of all slices in the window
is used because the per-slice rate is noisy (slices that span a job change finish
short). "Reported avg N/s" is the miner's own rolling EMA (`hashrate: ... (avg ...)`)
sampled at the end of the run; it reads higher because it weights instantaneous
peaks. Both are reported. Top candidates (2626, 16384, 32768, 65536) were run twice;
the table shows the mean of the two per-slice medians for those rows.

### VRAM accounting

nvidia-smi's per-process `used_memory` undercounts CUDA pool/async allocations
(it reported only ~674 MiB for the miner while total-used rose ~2.4 GB). The honest
miner footprint is therefore derived from the **total-used delta minus the resident
python baseline (4390 MiB)**. Both "VRAM total" (whole card) and "VRAM proc"
(miner-attributable = total - 4390) are listed.

## Results

| batch | per-slice N/s (median) | reported avg N/s | GPU util % | power W | VRAM total MiB | VRAM proc MiB | vs 2626 | notes |
|------:|-----------------------:|-----------------:|:----------:|:-------:|---------------:|--------------:|:-------:|-------|
| 2626  |  6,578,220 |  7,236,791 | 85 | 261-277 | 6851 | 2461 |   baseline | 0.2.32 auto pick; 2 runs |
| 4096  |  6,875,254 |  8,175,681 | 86 | 275 | 6729 | 2339 |  +4.5% | |
| 6144  |  9,092,976 |  9,266,766 | 84 | 318 | 6753 | 2363 | +38.2% | steep climb |
| 8192  | 10,224,951 | 13,037,468 | 83 | 350 | 6763 | 2373 | +55.4% | |
| 10240 | 10,573,637 | 11,610,094 | 82 | 363 | 6763 | 2373 | +60.7% | |
| 12288 | 11,293,054 | 13,785,140 | 82 | 374 | 6788 | 2398 | +71.7% | |
| 16384 | 12,005,903 | 14,949,001 | 82 | 408-421 | 6797 | 2407 | +82.5% | knee of curve; 2 runs |
| 24576 | 13,175,230 | 18,258,471 | 81 | 431 | 6828 | 2438 | +100.3% | |
| 32768 | 13,601,120 | 17,459,307 | 80-81 | 455-462 | 6849 | 2459 | **+106.8%** | recommended; 2 runs |
| 49152 | 13,596,199 | 19,168,387 | 80 | 460 | 6893 | 2503 | +106.7% | flat vs 32768 |
| 65536 | 14,151,290 | 19,449,795 | 80 | 492-494 | 6949 | 2559 | +115.1% | absolute peak; 2 runs |
| 98304 | 13,855,294 | 18,329,983 | 81 | 484 | 6933 | 2543 | +110.6% | regressed vs 65536 |
|131072 | 13,807,388 | 17,540,654 | 80 | 490 | 6951 | 2561 | +109.9% | regressed (2nd consecutive) |

Per-slice rate is monotonic and steep from 2626 to ~24576, flattens into a plateau
across 32768-65536, then turns over (98304 and 131072 are both below the 65536 peak
= two consecutive regressions, the stop condition). GPU utilization drifts *down*
slightly (85% -> 80%) as batch grows while power rises, the classic signature of
occupancy saturation rather than a memory wall. VRAM never exceeded ~6.95 GB of 32 GB.

## Recommendation

**`BTX_BATCH=32768`** (`--batch 32768`).

- **+107%** per-slice throughput over the batch=2626 auto baseline (6.58M -> 13.60M n/s).
- Within **4%** of the absolute-peak batch=65536 (14.15M n/s) while drawing ~35W less
  (455-462W vs 492-494W) and with tighter slice-to-slice variance.
- Best **nonces/watt** of the high-throughput configs (29.7k n/s/W vs 65536's 28.7k,
  +3.5%), matching this rig's stated optimization target.

If absolute peak raw rate is wanted regardless of power: **`--batch 65536`** (+115%
vs baseline, but +35W and noisier).

### Was the sweep VRAM/OOM-bounded?

No. It was bounded by GPU occupancy / compute. Peak VRAM was ~6.95 GB of 32 GB
(~21%); miner-attributable footprint stayed ~2.5 GB. Zero CUDA OOM, allocation
failures, or instability up to batch=131072. There is enormous unused VRAM headroom;
pushing batch higher only hurts throughput (the kernel saturates SM occupancy well
before it runs out of memory).
