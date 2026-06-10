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

Next on the digest path (spec'd, not yet implemented): factored compression —
distribute the compress weights over the block product (`word(i,j) =
Σ_x Σ_m A'[16i+x][m] · D_x[m][j]` with `D_x[m][j] = Σ_y W[x,y]·B'[m][16j+y]`),
cutting product MACs from n^3=134M to ~12.6M (~10x) per candidate. After that the
windowed matrix-gen SHA becomes the dominant cost.
