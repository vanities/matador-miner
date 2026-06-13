# PR #58 - CUDA hardware validation package

Standalone evidence that the CUDA solver patches are byte-exact and memory-clean
on a real Blackwell (RTX 5090, sm_120) card. Assembled in response to numair's
request on https://github.com/btxchain/btx/pull/58 to share the validation
harnesses on the public PR / fork path.

## Contents

| File | What it is |
|------|------------|
| `validate-matmul-patches.cu` | Parity harness: nonce-seed matrix gen, fused + factored product digest, device-prepared-input path. Byte-exact vs unpatched kernel + CPU reference. |
| `validate-sha-windowed-scanner.cu` | Parity harness: windowed-SHA nonce scanner vs original `w[64]` compress. |
| `raw-output.txt` | Full annotated transcript: every command plus its output, captured on the 5090. |
| `run-validation.sh` | Reproduces `raw-output.txt`: compiles both harnesses and runs each under compute-sanitizer (memcheck/synccheck/racecheck). |
| `COMMENT.md` | Paste-ready PR #58 comment body. |

## Result summary

- Parity: 8/8 byte-exact checks PASS (matrixgen, retry/fallback, midstate, fused, factored, scanner ×2).
- compute-sanitizer: memcheck (matmul + scanner), synccheck (matmul), racecheck (matmul shared-mem), all 0 errors / 0 hazards.
- Environment: RTX 5090, driver 595.71.05, CUDA 12.8 (nvcc V12.8.61), compute-sanitizer 2025, built `-arch=sm_120 -O3`.

## Reproduce

```
nvcc -arch=sm_120 -O3 -o matmul_test validate-matmul-patches.cu && ./matmul_test
nvcc -arch=sm_120 -O3 -o sha_test   validate-sha-windowed-scanner.cu && ./sha_test
# or the full annotated capture incl. compute-sanitizer:
bash run-validation.sh 2>&1 | tee raw-output.txt
```

racecheck runs the full parity section with `BTX_VAL_NO_PERF=1`, which skips the
timing loop. Benchmarking under a sanitizer isn't representative (instrumentation
inflates and distorts timing), and the loop's ~120 shared-mem kernel re-launches
would otherwise overrun racecheck's access-record tracker. `FusedOrig`/`FusedNew`
are the only kernels that declare `__shared__`, and the parity section exercises them.
