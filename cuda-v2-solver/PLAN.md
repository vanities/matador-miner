# BTX v2 (nonce-seed) batched CUDA solver — prototype plan

Goal: restore GPU-bound mining for **MatMul nonce-seed v2** (active at block 125,000),
where the per-nonce matrix seed defeats the v1 fixed-matrix GPU batching and the node
falls back to a parallel-CPU, batch-of-1-GPU path (`SolveMatMulParallel` →
`SolveMatMulNonceSeeded`, pow.cpp:2846 / 2624). On a 5090 this leaves the GPU ~idle
(~6%) and pegs the CPU (~600% pre-fix, ~1200% with `BTX_MATMUL_SOLVER_THREADS=12`).

## Why v2 is CPU-bound (the gap)
- v1: `seed_a/seed_b = f(prevhash, height)` → fixed per block → one matrix pair, reused
  across a big GPU nonce batch (`g_from_seed_cache` hits). GPU-bound, fast.
- v2: `seed_* = DeterministicMatMulSeedV2(header_incl_nonce, height, which)` (pow.cpp:63)
  → **new seed every nonce** → `SharedFromSeed` cache never hits → CPU rebuilds two
  512×512 M31 matrices per nonce (matrix.cpp:491 `FromSeed`: `out[r*n+c]=from_oracle(seed,r*n+c)`),
  then submits a **batch of one** to the GPU (pow.cpp:2727). CPU matrix-gen is the bottleneck.

## What already exists on the GPU (confirmed byte-exact)
- `src/cuda/oracle_accel.cu`:
  - `__device__ FromOracle(seed, index)` (line 712) == CPU `field::from_oracle` (field.cpp:140). **Verified match.**
  - Full `__device__` SHA256 (`Sha256Init`/`Sha256Compress`, lines 586/613).
  - Pattern kernels `GenerateOracleNoiseKernel` / `GenerateOracleVectorKernel` (725/746) — same shape we need.
- `src/cuda/matmul_accel.cu` + `src/matmul/accelerated_solver.cpp`: GPU matmul + digest, and a
  device-resident-matrix path (`use_uploaded_base_matrices`, accelerated_solver.cpp:1135).

## The missing piece (what we build)
A kernel that, for a batch of K nonces, generates the per-nonce base matrices A,B
**on-device** via `FromOracle` and feeds the existing matmul/digest — never building
matrices on the CPU nor transferring them over PCIe.

### Step 1 — base-matrix kernel (mirrors CPU `FromSeed`)
```cuda
// out is row-major n*n; element idx = from_oracle(seed, idx), exactly like CPU FromSeed.
__global__ void GenerateBaseMatrixKernel(OracleSeedBytes seed, uint32_t* out, uint32_t total) {
    uint32_t idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < total) out[idx] = FromOracle(seed, idx);   // FromOracle already in oracle_accel.cu
}
// launch: total = n*n = 262144; grid = ceil(total/256), block = 256; one launch per matrix,
// or a 2D grid (idx, which_matrix) to do all 2K matrices of a batch in one launch.
```

### Step 2 — per-nonce seed derivation on device
`DeterministicMatMulSeedV2` = `SHA256("BTX_MATMUL_SEED_V2" ‖ hashPrevBlock ‖ height ‖
nVersion ‖ hashMerkleRoot ‖ nTime ‖ nBits ‖ nNonce64 ‖ matmul_dim ‖ which)` (pow.cpp:63).
Only `nNonce64` varies across a batch → precompute the fixed prefix's SHA midstate on host,
feed (nonce, which) on device. GPU SHA256 already present. **Must match HashWriter byte order exactly.**

### Step 3 — batched solve
For K nonces: derive 2K seeds → GenerateBaseMatrixKernel ×2K (device) → existing matmul+digest
×K (device) → compare digests to target on device → return first hit. Keep everything device-resident.

### Step 4 — integrate
Replace the per-nonce CPU body of `SolveMatMulNonceSeeded` with the batched device path when
`active_backend == CUDA`. Keep the CPU path as fallback.

## Validation (non-negotiable — consensus-exact)
1. Standalone harness: CPU `from_oracle` vs GPU `FromOracle` over many (seed,index) — byte-exact.
2. CPU `FromSeed(seed,512)` vs GPU `GenerateBaseMatrixKernel` — full-matrix byte-exact.
3. End-to-end: GPU digest for a known header/nonce == CPU canonical digest (the node already
   has `BTX_MATMUL_CPU_CONFIRM` to CPU-confirm GPU hits — keep it on while validating).
A wrong kernel only yields self-rejected blocks (safe), but we validate before trusting throughput.

## Build / deploy constraints
- Build needs nvcc → compile via the Docker CUDA *devel* image (same as the miner Dockerfile
  builder stage), against `BTX_CUDA_ARCHITECTURES=120` (sm_120).
- **Do NOT deploy mid-activation**: any restart during the 124,999 reorg churn triggers a
  ~4-min shielded rebuild (chainstate/shielded height mismatch). Deploy only after 125,000 settles.
- Upstream (btxchain) will likely ship an official optimized v2 GPU solver first; watch for it.

## KEY SIMPLIFICATION (found during M1)
The v2 loop (`SolveMatMulNonceSeeded`) ALREADY computes `seed_a`/`seed_b` on the host per nonce
(cheap: 2 SHA256). So **Step 2 (device seed derivation) is NOT needed** for the minimal win — just
replace the two CPU `SharedFromSeed(seed,n)` calls with a GPU `FromSeedGpu(seed,n)`. The expensive
part (262144 from_oracle/matrix) moves to GPU; the cheap part (seed) stays on host. Minimal, localized.

## Status
- [x] Feasibility: GPU FromOracle == CPU from_oracle (byte-exact). Primitives all present.
- [x] **Step 1 DONE**: `GenerateBaseMatrixKernel` validated byte-exact vs CPU (all 262144 elems,
      seed 0..31) and benchmarked: **16,479 matrices/s on the 5090 (sm_120), ~8,239 nonces/s
      matrix-gen ceiling** — naive single-stream, vs CPU ~hundreds/s. Files: `validate.cu`,
      `gen_truth.py` (run via nvidia/cuda:12.8.0-cudnn-devel, `nvcc -arch=sm_120`).
- [x] Step 2 (SKIPPED — seeds already on host).
- [x] **Step 3 DONE**: added `GenerateBaseMatrixKernel` + thread-safe `GenerateBaseMatrixFromSeed`
      (per-thread stream + reused device buffer) to `src/cuda/oracle_accel.cu` (decl in
      `cuda/matmul_accel.h`); swapped CPU `SharedFromSeed`→`SharedFromSeedPreferGpu` at pow.cpp:2722
      (CUDA path, CPU fallback). 3 files, no CMake change. Built clean (incremental).
- [x] **Step 4 DONE (2026-06-08)**: regtest with v2 forced active from genesis
      (`-regtestmatmulnonceseedheight=0 -regtestmatmulproductdigestheight=0 -regtestmatmulbindingheight=0`):
      mined 20 v2 blocks via GPU, node accepted them, **`verifychain 4 0 = true`** (full re-validation),
      log "MatMul v2: GPU base-matrix generation ACTIVE". Consensus-exact end-to-end. (regtest n=64;
      mainnet n=512 kernel separately proven byte-exact in M1, same n-agnostic wiring.)
- [ ] Step 5 PRODUCTION build via the real Dockerfile (CUDA-13, ubuntu24.04) + DEPLOY — post-activation
      only (restart during churn = 4-min shielded rebuild). Optional first: benchmark integrated
      nonces/s vs CPU; quick n=512 integrated re-check.
- [ ] Optimization backlog: keep matrices device-resident (skip the gen->host->matmul roundtrip),
      batch K nonces/launch. Current naive version already correct + matrix-gen ~30-100x CPU.

## Build env (reusable): pc container `btxbuild` (nvidia/cuda:12.8.0-cudnn-devel, --gpus all,
## /src = ~/btx-build-src). Full build 106s; incrementals ~30-60s. `docker exec btxbuild bash /src/regtest_validate.sh`.

## Optimization backlog (after a correct integration works)
- Keep matrices device-resident and feed the matmul directly (avoid the gen->host->matmul roundtrip).
- Batch K nonces per launch (grid.y) + per-worker streams to saturate the GPU.
