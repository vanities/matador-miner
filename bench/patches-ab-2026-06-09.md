# A/B: matmul digest patches on 0.32.3 (2026-06-09)

`btx-matmul-solve-bench --backend cuda --n 512 --b 16 --r 8 --iterations 100`,
miner stopped, RTX 5090 stock clocks/power. Median nonces/s of 100 iterations.

| Image | Patches | Median n/s | vs prev |
|-------|---------|-----------:|--------:|
| `btx-miner:prev` (`a8854e4be6a3`) | scanner only | 126,066 | — |
| `btx-miner:local` (`488926ca959c`) | + matrixgen + fused | **199,319** | **+58.1%** |
| same + `BTX_MATMUL_CUDA_POOL_SLOTS=8` | (slots 6→8) | 200,020 | +0.4% (noise — knob not worth wiring) |

Kernel-level (validator, contended w/ live miner, ratio = signal):
- matrix-gen (windowed SHA): 0.70 → 0.22 ms, **~3.1x**
- fused product (single reduction): 0.70 → 0.30–0.47 ms, **~1.5–2x**

Byte-exactness (patches/validate-matmul-patches.cu, run on the 5090): 2,097,152
matrix-gen elements, 65,536 retry/fallback edge cases, 4,096 fused words vs stock
kernel AND CPU reference — **0 mismatches** across all four checks.

## Round 2 (same day): factored compression

Implemented as `patches/factored-compression.patch` — distributes the compress
weights over the block product (`D[j][x][m] = Σ_y W[x,y]·B'[m][16j+y]` once per
request, then `word(i,j) = Σ_x Σ_m A'[16i+x][m]·D[j][x][m]`, one warp per word),
cutting product MACs from n³=134M to ~12.6M (~10.6×) per candidate.

| Image | Patches | Median n/s | vs prev |
|-------|---------|-----------:|--------:|
| `btx-miner:prev2` (`488926ca`) | 3 patches | 198,114 | — |
| `btx-miner:local` (`9eecc41b`) | + factored | **485,967** | **+145%** |

Kernel-level: factored K1+K2 0.073 ms vs single-reduction fused 0.465 ms (**~6.4×**);
byte-exact vs the stock fused kernel (4096 words, 0 mismatches). Live: zero
CPU-confirm mismatches post-deploy (exercises the packed-pointers variant).

## Round 3 (same day): K2 2×2 tiles + scanner template midstates

| Image | Patches | Median n/s | vs prev |
|-------|---------|-----------:|--------:|
| `btx-miner:prev3` (`9eecc41b`) | 4 patches | 488,981 | — |
| `btx-miner:local` (`a2b431d0`) | + 2×2 K2 + midstate scanner | **564,473** | **+15.4%** |

- `factored-compression.patch` updated: warp now computes a 2×2 word tile
  (halves A/D L2 traffic at production batch sizes; flat at validator scale).
- `template-midstate-scanner.patch`: block 0 of both scan messages is
  nonce-independent (nonce @99/76, `which` @109) → midstates once per CUDA
  block, 8 → 5 SHA compressions per scanned nonce. Validated vs the ORIGINAL
  w[64] scanner: 200k nonces, 0 mismatches.

Day total: **126,066 → 564,473 median nonces/s (4.48×)**, all five patches
byte-exact-validated and upstreamed as btxchain/btx PR #58. Remaining headroom:
the digest is matrix-gen-SHA-bound; scanner ceiling ~2.47M n/s. Parked ideas:
8-round seed midstate inside matrix-gen (~+5% e2e), int8-limb tensor-core M31
GEMM (~2× theoretical, high risk).
