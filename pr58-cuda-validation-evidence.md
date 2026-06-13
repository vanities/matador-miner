## CUDA hardware validation evidence (RTX 5090)

Following up on the close note re: btx-node #259, here's the CUDA hardware-validation pass on a real Blackwell card. All parity and compute-sanitizer checks are clean.

### Environment

| | |
|---|---|
| GPU | NVIDIA GeForce RTX 5090 (Blackwell, sm_120) |
| Driver | 595.71.05 |
| Toolchain | CUDA 12.8 (nvcc V12.8.61), `-arch=sm_120 -O3` |
| compute-sanitizer | NVIDIA Compute Sanitizer 2025 |

(The production miner builds the same `src/cuda/*` with CUDA 13; the standalone harnesses below were built with 12.8. Byte-exactness is algorithm-determined, so it holds across both.)

### 1. Byte-exact CUDA-vs-reference parity

Standalone harnesses that run each patched kernel against the **unpatched kernel** and, for the digest, against an **independent CPU reference**. Random seeds/matrices, run on the 5090:

```
matrixgen byte-exact:          seeds=8 elements=2,097,152  mismatches=0  -> PASS
retry/fallback byte-exact:     cases=65,536                mismatches=0  -> PASS   (the candidate>=MODULUS / oracle-fallback paths, exercised directly)
matrixgen midstate byte-exact: elements=2,097,152          mismatches=0  -> PASS
fused orig-vs-new byte-exact:  words=4,096                 mismatches=0  -> PASS
fused vs CPU reference:        pairs=64                    mismatches=0  -> PASS
factored vs fused-orig:        words=4,096                 mismatches=0  -> PASS
scanner windowed-SHA:          nonces=200,000              mismatches=0  -> PASS
scanner midstate:              nonces=200,000              mismatches=0  -> PASS
```

Coverage maps to the cases you flagged: nonce-seed matrix gen, product digest (fused + factored), device-prepared-input (the factored packed-pointers path), and nonce-scan (scanner SHA). Harnesses: `validate-matmul-patches.cu`, `validate-sha-windowed-scanner.cu` (happy to attach).

### 2. compute-sanitizer (clean)

```
memcheck   (matmul kernels):  ERROR SUMMARY: 0 errors
synccheck  (matmul barriers): ERROR SUMMARY: 0 errors
memcheck   (scanner kernel):  ERROR SUMMARY: 0 errors
racecheck  (matmul shared-mem): RACECHECK SUMMARY: 0 hazards displayed (0 errors, 0 warnings)
```

memcheck (out-of-bounds / leaks / misaligned), synccheck (divergent `__syncthreads`), and racecheck (shared-memory hazards in the tree-reduction kernels) all clean.

### 3. Live mainnet CPU confirmation

The patched solver has run on BTX mainnet across 0.32.3 → 0.32.6 with `cpu_confirm_candidates` enabled (the node re-checks GPU digests against the CPU path). **Zero GPU-vs-CPU digest mismatches** logged over millions of confirmed digests, while staying on the canonical chain (e.g., one spot-check post-0.32.4: 821,353 CUDA digests, 0 fallbacks, 0 mismatches). The factored packed-pointers variant the standalone harness can't reach is exercised here.

### 4. Throughput (context, not a gate)

`btx-matmul-solve-bench`, **v2 nonce-seed mode** (`--nonce-seed-height 0 --product-digest-height 0`, n=512 b=16 r=8), the cache-free mode live mining actually uses:

```
clean v0.32.x:        54,964 nonces/s (median)
with the patches:    163,699 nonces/s (median)   ~2.98x
```

The default bench mode reuses one seed and caches matrix generation, which overstates the gain; the above are the cache-free numbers.

---

Net: parity is byte-exact, compute-sanitizer is clean across memcheck/synccheck/racecheck, and the path has a multi-version mainnet run with zero CPU-confirm mismatches. Glad to re-run any specific case (or against a particular toolchain) if it helps #259 along.
