@numair thanks, keeping it all on the public path here. Pushed the standalone validation harnesses to the branch so they're reviewable/reproducible in-repo:

**[`src/cuda/validation/`](https://github.com/vanities/btx/tree/cuda-windowed-sha-scanner/src/cuda/validation)** (commit `46fff93`)

- [`validate-matmul-patches.cu`](https://github.com/vanities/btx/blob/cuda-windowed-sha-scanner/src/cuda/validation/validate-matmul-patches.cu): nonce-seed matrix gen, fused + factored product digest, and the device-prepared-input (packed-pointers) path, each byte-exact vs the unpatched kernel and (for the digest) an independent CPU reference.
- [`validate-sha-windowed-scanner.cu`](https://github.com/vanities/btx/blob/cuda-windowed-sha-scanner/src/cuda/validation/validate-sha-windowed-scanner.cu): windowed-SHA nonce scanner, byte-exact vs the original `w[64]` compress.
- [`raw-output.txt`](https://github.com/vanities/btx/blob/cuda-windowed-sha-scanner/src/cuda/validation/raw-output.txt): full annotated transcript (every command plus its output), and [`run-validation.sh`](https://github.com/vanities/btx/blob/cuda-windowed-sha-scanner/src/cuda/validation/run-validation.sh) to reproduce it.

Build/run is a one-liner each (CUDA 12.8, `-arch=sm_120`):

```
nvcc -arch=sm_120 -O3 -o matmul_test validate-matmul-patches.cu && ./matmul_test
nvcc -arch=sm_120 -O3 -o sha_test   validate-sha-windowed-scanner.cu && ./sha_test
```

### Raw output (RTX 5090, sm_120, driver 595.71.05, nvcc 12.8.61)

```
matrixgen byte-exact:          seeds=8 elements=2,097,152  mismatches=0 -> PASS
retry/fallback byte-exact:     cases=65,536                mismatches=0 -> PASS
matrixgen midstate byte-exact: elements=2,097,152          mismatches=0 -> PASS
fused orig-vs-new byte-exact:  words=4,096                 mismatches=0 -> PASS
fused vs CPU reference:        pairs=64                    mismatches=0 -> PASS
factored vs fused-orig:        words=4,096                 mismatches=0 -> PASS
scanner windowed-SHA:          nonces=200,000              mismatches=0 -> PASS
scanner midstate:              nonces=200,000              mismatches=0 -> PASS

compute-sanitizer:
  memcheck  (matmul kernels):     ERROR SUMMARY: 0 errors
  synccheck (matmul barriers):    ERROR SUMMARY: 0 errors
  memcheck  (scanner kernel):     ERROR SUMMARY: 0 errors
  racecheck (matmul shared-mem):  RACECHECK SUMMARY: 0 hazards displayed (0 errors, 0 warnings)
```

On the racecheck run: it covers the **full parity section**. `BTX_VAL_NO_PERF=1` just skips the timing loop. Benchmarking under a sanitizer isn't representative (the instrumentation inflates and distorts timing), and the loop's ~120 shared-mem kernel re-launches would otherwise overrun racecheck's access-record tracker. All shared-memory work is in `FusedOrig`/`FusedNew` (the only kernels declaring `__shared__`, the `partials[]` tree-reduction), which the parity section exercises. As a sanity check that the 0 is real and not vacuous, I deliberately removed the reduction's `__syncthreads()` and re-ran: racecheck then flags the write/read race in `FusedOrig` (millions of hazards, exit 1). So the clean run's 0 hazards is a genuine result.

Happy to re-run any specific case or against a different toolchain.
