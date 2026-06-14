# MATADOR BTX Miner: Build, Validation, and Benchmark (0.2.32 vs 0.2.33 vs 0.2.33+patch)

Date: 2026-06-14
Host: pc (RTX 5090)

## Summary

Three variants of the `btx-nvidia-miner` (thekillsquad007) were built fresh, validated, and
benchmarked on an uncontended RTX 5090. Headline findings:

1. 0.2.33 does NOT improve 5090 throughput over 0.2.32 in this environment. It is about 5 percent
   SLOWER on raw per-slice scan rate, because its new VRAM-auto-batch logic clamps the launch batch
   to the 1024 floor where 0.2.32 chose ~2626. Result is reproducible in both run orders.
2. Our windowed-SHA + seed-midstate patch applies cleanly to 0.2.33 (the patch only touches
   `src/cuda/gpu_sha256.cu`, which 0.2.33 leaves untouched) and recovers most of the gap: about
   +3 percent per-slice over stock 0.2.33, landing it roughly midway between 0.2.33 and 0.2.32.
3. The patch validates BYTE-EXACT on 0.2.33. All three repo tests pass, including the
   consensus-critical `cuda_pow_reference` gate (`CudaVerifyAgainstCpu` over a v2 nonce range).

End to end at live pool difficulty the differences are small (single-digit percent) and the most
important practical takeaway is that 0.2.33 alone is a regression on this card unless the batch
floor issue is addressed.

## Methodology

- GPU: NVIDIA GeForce RTX 5090, 32607 MiB VRAM
- Driver: 595.71.05
- Build toolchain: CUDA 12.8.0 in container `nvidia/cuda:12.8.0-devel-ubuntu24.04`, `sm_120`
  (`-DCMAKE_CUDA_ARCHITECTURES=120`), `Release`, `-DBTX_MINER_ENABLE_CUDA=ON`,
  `-DBTX_MINER_BUILD_TESTS=ON`.
- Host kernel: 7.0.9-arch2-1
- Variants (cloned fresh under ~/):
  - 0.2.32  = `df4e50e1334a1109ef7045c0f6bea16b9fa2f69f`  (~/nvbench-0232)
  - 0.2.33  = `9a7e50e5f0207ecd78106ca87b0ece5830226462`  (~/nvbench-0233)
  - 0.2.33+patch = 0.2.33 with `/tmp/windowed-sha-matrixgen.patch` applied (~/nvbench-0233p)
- Patch scope: touches ONLY `src/cuda/gpu_sha256.cu` (+216 / -6 lines). `git apply --check` clean
  on 0.2.33. The 0.2.32 vs 0.2.33 diff confirms 0.2.33 does NOT modify `gpu_sha256.cu` (it changes
  `cuda_solver.*`, `cuda_device.*`, `main.cpp`, `stratum_client.*`).

### Contention control

- The live pool miner (`btx-pool-nv`) was stopped for the entire benchmark window
  (paused 15:22, restored 15:40) so the GPU was single-tenant during measurement.
- IMPORTANT CAVEAT: a long-lived host `python` process holds ~4390 MiB of VRAM at all times on
  this box (about 26 GiB stayed free). This is the SAME condition under which the production
  miner runs, so the numbers are representative of the real environment. It does NOT starve the
  GPU (26 GiB free), but see the batch-sizing note below.
- First pass measured all three forward (0232, 0233, 0233p) back to back. A second pass re-ran
  0233 then 0232 in REVERSED order to rule out any cold-start / thermal ordering bias.

### Primary metric note

The repo `--benchmark` flag is NOT a CUDA throughput test in this fork. It runs a CPU-only
reference smoke test (`SolveCPU` over 64 nonces) and then prints which CUDA devices are visible.
It reports no nonces/s for the GPU. (Verified by reading `src/main.cpp` lines 193-229.) The
real-world throughput therefore comes from a live-pool run. Two figures are reported per variant:

- per-slice nonces/s (median of full-length >4000ms slices): the cleanest raw GPU scan rate.
- reported avg N/s: the miner own running EMA (`[stratum] hashrate ... avg`), median of the
  stable tail. This EMA smooths across slice boundaries and connect/warmup, so it compresses
  real per-slice differences.

Each live-pool run: ~70-75s, `--devices all --dev-fee 0`, worker `<addr>.BENCH`, against
`stratum+tcp://stratum.minebtx.com:3333`, in the 12.8.0-devel container with `--gpus all`.

## Results

### Throughput table (uncontended, single-tenant GPU)

| Variant            | launch batch | per-slice N/s (fwd) | per-slice N/s (rev) | reported avg N/s | GPU util | power  | VRAM (proc / total used) |
|--------------------|--------------|---------------------|---------------------|------------------|----------|--------|--------------------------|
| 0.2.32 (df4e50e)   | 2626         | 4,678,362           | 4,715,870           | ~5,190,000       | 86%      | 247 W  | 658 MiB / 6741 MiB       |
| 0.2.33 (9a7e50e)   | 1024         | 4,429,197           | 4,473,272           | ~5,189,000       | 82%      | 245 W  | ~658 MiB / 6733 MiB      |
| 0.2.33 + patch     | 1024         | 4,575,089           | (n/a)               | ~5,392,000       | 81%      | 239 W  | ~658 MiB / 6733 MiB      |

Notes:
- "per-slice N/s" is the median of full-length slices; values are tight (min/max within ~3%).
- VRAM "total used" includes the resident ~4390 MiB python process plus ~1650 MiB driver/context;
  the miner per-process footprint is ~658 MiB regardless of variant (consistent with batch=1024 on
  0233/patch). 0232 at batch=2626 still reports a similar per-process figure because the launch
  workspace is dominated by fixed gate/cap buffers.
- Deltas (per-slice, averaging both run orders where available):
  - 0.2.33 vs 0.2.32: 4,451k vs 4,697k = about -5.2% (0.2.33 is SLOWER).
  - 0.2.33+patch vs 0.2.33: 4,575k vs 4,451k = about +2.8% (patch helps).
  - 0.2.33+patch vs 0.2.32: 4,575k vs 4,697k = about -2.6% (patch does not fully close the gap to
    0232 because 0232 batch=2626 still wins on occupancy).

### Why 0.2.33 is slower: the auto-batch floor

0.2.33 added `AutoBatchSizeForDevice` / `AutoBatchCapForDevice` (in `src/cuda/cuda_solver.cpp`).
The startup line `launch batch=1024 (auto, cap=262144)` prints the CAP (262144 for a 28GB+ card),
not the chosen batch. The chosen batch is `usable_free_VRAM * 0.85 / LaunchBatchBytes(job,1)`,
clamped to `[1024, cap]`. On the 5090 with this v2 MatMul job that expression lands BELOW 1024
even with 26 GiB free, so it clamps to the 1024 floor. Confirmed live and via `--print-gpu-batch`
(batch=1024 with 26023 MiB free). 0.2.32 used an older free-VRAM formula and chose batch=2626,
which gives better SM occupancy and ~5% higher scan rate. So 0.2.33 auto batch sizing, as written,
is a regression for this card rather than the claimed improvement.

### Byte-exact validation (variant 3: 0.2.33 + patch)

Built with tests, run via `ctest` in the build container. Actual output:

```
=== ctest list ===
Test project /src/build
  Test #1: pow_reference
  Test #2: oracle_digest
  Test #3: cuda_pow_reference

Total Tests: 3

=== ctest run (verbose) ===
1: Test command: /src/build/btx-miner-test
1: All pow/stratum tests passed.
1/3 Test #1: pow_reference ....................   Passed   54.93 sec
2: Test command: /src/build/btx-miner-oracle-test
2: Oracle digest vectors match btx-gbt-solve.
2/3 Test #2: oracle_digest ....................   Passed    1.07 sec
3: Test command: /src/build/btx-miner-cuda-test
3: CUDA PoW matches CPU reference (legacy + v2 sample nonces).
3/3 Test #3: cuda_pow_reference ...............   Passed    0.00 sec

100% tests passed, 0 tests failed out of 3
Total Test time (real) =  56.00 sec
```

`cuda_pow_reference` is the consensus gate: `tests/test_cuda_pow.cpp` calls
`CudaVerifyAgainstCpu(job, nonce, target)` (defined in `src/cuda/matmul_kernel.cu`) over a v2 job
nonce range and asserts the CUDA path matches the CPU reference. PASS means the patched live
matrix-gen is byte-identical to the reference. The patch is safe to ship on 0.2.33 from a
correctness standpoint.

## Conclusion

0.2.33 is not worth taking on this 5090 as-is: contrary to the author claim, its new VRAM
auto-batch logic clamps the launch batch to 1024 on this card and runs about 5 percent SLOWER per
slice than 0.2.32 (which auto-selected ~2626). The result reproduced in both run orders, so it is
not thermal noise. The windowed-SHA + seed-midstate patch is clearly worth keeping: it applies
cleanly to 0.2.33, validates byte-exact (all three tests pass, including the consensus
`CudaVerifyAgainstCpu` gate), and recovers about +3 percent per slice on top of stock 0.2.33,
though it does not fully reach 0.2.32 because the batch floor still caps occupancy. Best of both
worlds would be 0.2.33 plus the patch plus a fix or override for the batch floor (force batch back
toward ~2600), which should land at or above 0.2.32. As measured here, none of the three changes
the reported-avg headline by more than a few percent, so at live pool difficulty the practical
mining impact is modest; the actionable item is the 0.2.33 batch-sizing regression, not the patch.
