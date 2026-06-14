# Solver CUDA Kernel Comparison: Official btxchain/btx vs MATADOR

Read-only static comparison. No GPU touched, no live miner disturbed (source reads +
cuobjdump/strings on a copied binary only).

- Official source: btxchain/btx @ 33c7975 (v0.32.10, PR #67 release prep). The pool's
  btx-gbt-solve is built from this. CUDA in src/cuda/oracle_accel.cu (scanner + oracle)
  and src/cuda/matmul_accel.cu (matrix gen + digest).
- MATADOR source: ~/nvminer-dev @ 9a7e50e (v0.2.33, thekillsquad007 fork). CUDA in
  src/cuda/matmul_kernel.cu (everything) + src/cuda/gpu_sha256.cu (batched gen kernels).
  NOTE: head is 9a7e50e (v0.2.33), not df4e50e as the task stated.
- Closed binary: /tmp/ggs, copied from btx-miner-pool:prev2 :/opt/dexbtx/bin/btx-gbt-solve.

## TL;DR

At live difficulty the SCANNER dominates, and the two scanners are ALGORITHMICALLY
IDENTICAL: both do exactly 5 SHA-256 compressions per nonce (8 -> 5 via a once-per-block
block-0 midstate), byte-for-byte the same message layout and gate test. MATADOR is
actually AHEAD of the open code: its on-GPU scanner carries the v3 parent-context
(BTX_MATMUL_SEED_V3 + parent_mtp), which the open v0.32.10 GPU scanner does NOT have
(it is v2-only). Matrix-gen and the product digest are also at parity (same 2-kernel
seed-midstate precompute, same fused compression).

The ONLY scanner deltas are micro-architectural, not algorithmic:
1. MATADOR computes the two block-0 midstates in a separate <<<1,1>>> kernel into global
   memory; official computes them in __shared__ once per CUDA block inside the scan
   kernel itself. Official avoids one kernel launch + a global round-trip.
2. MATADOR's gate emits seed_a/seed_b/sigma for survivors (no re-derivation downstream);
   official emits only a pass flag, so survivors re-derive. MATADOR wins here.

Net: there is NO large scanner win to port from the official kernels. The biggest
realistic MATADOR scanner gain is folding init_scan_midstates_kernel into
sigma_gate_kernel as a shared-memory hoist (item 1), a small constant-overhead win.

## Decompile: btx-gbt-solve kernel entry points

cuobjdump --dump-ptx /tmp/ggs, unique .entry set (fat binary: sm_61/75/80/86/89):

From _oracle_accel_cu (module hash fc903b0f):
- ScanNonceSeedPreHashKernel      <- the scanner
- GenerateOracleNoiseKernel
- GenerateOracleVectorKernel

From _matmul_accel_cu (module hash a7ed2368):
- PrecomputeSeedMidstatesKernel
- GenerateBaseMatrixFromSeedMidstateKernel
- GenerateBaseMatrixFromSeedBatchKernel
- BuildPerturbedMatrixKernel / BuildPerturbedMatrixPackedPointersKernel
- ApplyPerturbationPackedPointersVariableBaseKernel
- BuildFactoredRhsKernel / BuildFactoredRhsPackedPointersKernel
- ComputeFactoredWordsKernel
- ComputeCompressedWordsFusedKernel<0|1> / ...PackedPointersKernel<0|1>

Verdict: btx-gbt-solve's kernels EQUAL the official open btxchain/btx kernels exactly
(same mangled names incl. the per-TU module hashes fc903b0f / a7ed2368). There are NO
dexbtx-specific kernels. PR58 is upstreamed and the closed binary just links it. The
binary contains the BTX_MATMUL_SEED_V2 tag string but NOT BTX_MATMUL_SEED_V3, confirming
its on-GPU scanner is v2-only (no parent-context). It carries the host-side prehash-scan
plumbing (g_matmul_gpu_prehash_scan_attempts/successes/failures, CheckMatMulPreHashGate,
DeriveSigma). Its orchestration is GPU-starved on the 5090 and is NOT a model to copy;
kernels are what matter and they are identical to open.

Strings of interest re feeding/batch: CLI flags --batch-size, --matmul-b (16),
--matmul-n (512), --matmul-r (8), --seed-a/--seed-b; SubmitMatMulDigestPreparedBatchForMining,
ComputeCompressedWordsLowRank{,VariableBase}DeviceBatchMultiDevice. Nothing about its
batch/feeding reveals a kernel-level trick MATADOR lacks; it is the standard prepared-
batch multi-device submit path.

## SCANNER comparison (the throughput-dominant kernel)

Live regime: height >= 125000 (kMatMulSeedV2Height); v3 path activates at 130500
(kMatMulSeedV3Height, matmul_pow.h:12-14). Both sides use the per-nonce seed derivation.

Per-nonce SHA-256 compressions (identical on both sides):
- seed_a: BTX_MATMUL_SEED_V2 msg = 110 B -> total_blocks=(110+9+63)/64=2, block0 cached -> 1
- seed_b: same 110 B (only the final `which` byte differs, still block 1)         -> 1
- header_hash: header msg = 150 B -> total_blocks=3, block0 cached                 -> 2
- sigma = Sha256Bytes(header_hash, 32B) -> total_blocks=1                          -> 1
- TOTAL = 5 compressions/nonce, + 2 amortized block-0 compressions per CUDA block.
  (v3 seed msg = 118 B with parent_mtp; still 2 blocks -> still 1 compression. parent_mtp
   sits at byte offset 51..58, inside block 0, so it folds into the seed midstate for free.)

| Dimension                       | Official btxchain/btx                                  | MATADOR                                                       | Winner |
|---------------------------------|--------------------------------------------------------|--------------------------------------------------------------|--------|
| Scan kernel                     | ScanNonceSeedPreHashKernel, oracle_accel.cu:943        | sigma_gate_kernel, matmul_kernel.cu:1628                      | tie    |
| Granularity                     | 1 thread / nonce; <<<scan_blocks,256>>> (1337)         | 1 thread / nonce; <<<gate_blocks,256>>> (2483)               | tie    |
| Compressions / nonce            | 5 (comment "8 -> 5", oracle_accel.cu:955)              | 5 (same d_sha256_bytes_from_midstate math, :358)            | tie    |
| Block-0 midstate count          | 2 (seed + header), oracle_accel.cu:782 Sha256Block0Midstate | 2 (seed + header), d_sha256_block0_midstate :344         | tie    |
| Midstate SCOPE                  | __shared__, computed once / CUDA block in-kernel (959-973) | global mem, separate init_scan_midstates_kernel<<<1,1>>> (1618, launched 2478); scan threads read global (1648-1650) | OFFICIAL |
| Extra kernel launch for midstate| none (folded in)                                       | yes (init_scan_midstates_kernel)                             | OFFICIAL |
| v3 parent-context (parent_mtp)  | NOT present (BuildMatMulSeedV2Message only, :813; binary has no V3 tag) | present: d_build_matmul_seed_message v2/v3 branch, parent_mtp at off 51, matmul_kernel.cu:608-650 | MATADOR |
| Gate output for survivors       | pass flag only (out_flags, :998); survivors re-derive seed/sigma later | seed_a+seed_b+sigma+index emitted (1668-1675); survivors skip re-derivation | MATADOR |
| Gate test                       | Uint256InternalBytesLessOrEqual (:932)                 | d_sigma_below_prehash (:982), same LE-on-internal-bytes      | tie    |
| Survivor compaction             | host scans flag array, no on-GPU compaction (1380+)    | atomicAdd compaction on GPU (1670), only survivors copied to host | MATADOR |

Conclusion: on the metrics the task asked about (compressions/nonce, midstate width,
v3 hoisting) MATADOR meets or beats official. The single place official is cleaner is
the in-kernel shared-memory midstate (saves a <<<1,1>>> launch + a global read per
thread). That is the only scanner port target, and it is a constant-overhead win, not
a per-nonce-arithmetic win.

## Matrix-gen comparison

Both use the SAME 2-kernel seed-midstate design (precompute one 16-word midstate per
seed once, then resume every element's hash at SHA round 8 -> save 8/64 rounds, no
per-element barrier):

| Step                  | Official                                           | MATADOR                                            | Gap  |
|-----------------------|----------------------------------------------------|----------------------------------------------------|------|
| Per-seed midstate     | PrecomputeSeedMidstatesKernel, matmul_accel.cu:905 | ComputeSeedMidstatesKernel, gpu_sha256.cu:175      | none |
| Element gen           | GenerateBaseMatrixFromSeedMidstateKernel, :966 (CandidateFromMidstateScalars :932, resumes at round 8) | GenerateMatrixKernel, gpu_sha256.cu:685 (d_from_oracle_ms / d_candidate_from_midstate :454, resumes at round 8) | none |
| Rounds saved/element  | 8 of 64                                            | 8 of 64                                            | none |
| Retry/fallback        | FromOracle on candidate>=MODULUS (~2^-31)          | d_from_oracle_fast/d_fallback_candidate, same prob | none |

Parity. Note both authors independently found that the 2-kernel scalar precompute beats
a shared-memory midstate hoist here (official comment matmul_accel.cu:886-894; matches
MATADOR memory note "shared-mem midstate hoist 3x slower, use 2-kernel scalar form").
Nothing to port.

MATADOR's one-block-per-nonce matmul_nonce_kernel (matmul_kernel.cu:1525) uses an older
in-block d_compute_seed_midstate + d_fill_rect path, but that kernel is ONLY launched in
the legacy !use_v2 branch (matmul_kernel.cu:2453). At live height the v2 path runs the
batched gate -> ProcessPassedNoncesBatched (:2198), which uses the fast batched
GenerateMatrixKernel + batched perturb/compress, identical structure to official.

## Product-digest comparison

| Step                    | Official                                                    | MATADOR                                                  | Gap  |
|-------------------------|-------------------------------------------------------------|----------------------------------------------------------|------|
| Fused compress + reduce | ComputeCompressedWordsFusedKernel<bool>, matmul_accel.cu:1154; 1 CUDA block per (i,j) block-pair, block_size^2 active threads, shared `partials[]` tree reduce (ReducePartialsInPlace :1010 with warp shuffle for sm>=70) | batch_compressed_words_kernel / _512x16 variant, matmul_kernel.cu:1759/1831 | minor |
| Factored path           | BuildFactoredRhsKernel:1379 + ComputeFactoredWordsKernel:1451 | factored via batch_perturb + factored_rhs in d_solve_nonce | parity |
| Reduce cadence          | running 64-bit acc, periodic field reduce                   | d_reduce64 every kReduceInterval=4 (matmul_kernel.cu:730) | parity |

Both batch the compression across the whole survivor set. Official uses a per-block-pair
launch with a shared-memory tree reduction + warp-shuffle tail; MATADOR uses a flat
per-output-word grid. At live difficulty only a handful of nonces survive the gate, so
the digest is a negligible slice of runtime and any gap here is not worth byte-exactness
risk. No high-value port.

## Prioritized optimizations to port INTO MATADOR

Ordered by expected live impact. At live difficulty essentially every nonce dies in the
scanner, so only scanner-touching changes move the needle.

1. [SCANNER] Fold init_scan_midstates_kernel into sigma_gate_kernel as a __shared__
   hoist (mirror official ScanNonceSeedPreHashKernel:959-973).
   - What: in sigma_gate_kernel, have threadIdx.x==0 compute s_seed_midstate[8] and
     s_header_midstate[8] into __shared__, __syncthreads(), then every thread reads
     shared instead of the global seed_midstate/header_midstate pointers. Drop the
     separate init_scan_midstates_kernel<<<1,1>>> launch (matmul_kernel.cu:2478) and its
     d_seed_midstate/d_header_midstate global buffers.
   - Impact: small. Removes one kernel launch (~a few us) per batch + converts a per-
     thread global load into a shared load (already L1/broadcast-cached, so marginal).
     Realistic low-single-digit % on scanner wall time at large batch, more on tiny
     batches. This is the ONLY thing official does better in the scanner.
   - Byte-exactness risk: NONE. Identical math, identical inputs; this is exactly how
     official does it and the per-nonce result is bit-for-bit unchanged. The v3 branch
     stays in d_build_matmul_seed_message, so parent_mtp handling is preserved.

2. [SCANNER] Confirm/raise scanner occupancy: both use 256 threads/block. Verify register
   pressure is not capping occupancy on the 150-byte message buffers (uint8 message[150]
   + seed_a/b + sigma in registers/local).
   - What: nvcc -Xptxas -v (or cuobjdump --dump-resource-usage) on sigma_gate_kernel;
     if regs/thread forces <50% occupancy on sm_120, try __launch_bounds__(256) or shrink
     local arrays. The message buffer can be built incrementally rather than fully
     materialized (only block 1+ words are consumed after the midstate).
   - Impact: potentially the LARGEST available scanner win if occupancy is currently
     register-limited (the scan is the hot loop). Needs the resource-usage check to
     size; could be 0% (already maxed) or 10-20% (if it bumps an occupancy tier).
   - Byte-exactness risk: NONE for __launch_bounds__/occupancy tuning. LOW if rewriting
     the message buffer (must keep the exact byte layout feeding d_sha256_bytes_from_midstate).

3. [DIGEST, optional] Adopt official's shared-memory tree reduction + warp-shuffle tail
   (ReducePartialsInPlace, matmul_accel.cu:1010) for the compressed-words reduction if a
   future regime lets more nonces survive the gate (low epsilon_bits / low difficulty).
   - Impact: negligible at current live difficulty (few survivors); only matters if the
     gate pass-rate rises materially.
   - Byte-exactness risk: MEDIUM. Field-add is associative mod p so the sum is invariant,
     but reordering + warp-shuffle paths must be validated against the CPU reference with
     the existing parity harness before shipping.

4. [no-op] Matrix-gen: already at parity (same 2-kernel midstate precompute). Do NOT
   attempt a shared-memory midstate hoist; both codebases independently found it ~3x
   slower than the 2-kernel scalar form.

Recommendation: ship #1 (free, byte-exact, mirrors official), then run the resource-usage
check for #2 (highest upside). Skip #3/#4. None of these is a step-change because the
official kernels carry no scanner algorithm MATADOR lacks; MATADOR already matches the
5-compressions/nonce design and additionally carries the v3 parent-context the open
kernels do not.
