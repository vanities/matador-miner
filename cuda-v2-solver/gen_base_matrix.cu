// gen_base_matrix.cu — DRAFT (integrate into src/cuda/oracle_accel.cu, reusing its
// existing __device__ FromOracle / SHA256). This is the missing piece for v2 GPU mining:
// generate the per-nonce base matrices A,B on-device so the CPU stops rebuilding them.
//
// CPU reference being mirrored (matrix.cpp:491):
//   Matrix FromSeed(seed, n) { for r,c: out.at(r,c) = field::from_oracle(seed, r*n + c); }
// i.e. element index = r*n + c, value = from_oracle(seed, index). Row-major, n=512.
//
// FromOracle(seed,index) and OracleSeedBytes already live in oracle_accel.cu and are
// byte-exact with CPU field::from_oracle (verified against field.cpp:140). Do NOT
// reimplement them here — reference them so consensus stays exact.

// --- single matrix: one thread per element -----------------------------------
__global__ void GenerateBaseMatrixKernel(OracleSeedBytes seed,
                                         uint32_t* __restrict__ out,
                                         uint32_t total_elems /* = n*n */)
{
    const uint32_t idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < total_elems) {
        out[idx] = FromOracle(seed, idx);   // == CPU from_oracle(seed, idx)
    }
}

// --- batched: all 2*K matrices of a K-nonce window in one launch --------------
// seeds[2*K]: layout [a0,b0, a1,b1, ...]; out stride = total_elems per matrix.
// grid.y selects the matrix, grid.x*block covers its elements.
__global__ void GenerateBaseMatrixBatchKernel(const OracleSeedBytes* __restrict__ seeds,
                                              uint32_t* __restrict__ out,
                                              uint32_t total_elems,
                                              uint32_t num_matrices)
{
    const uint32_t m = blockIdx.y;
    if (m >= num_matrices) return;
    const uint32_t idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < total_elems) {
        out[(size_t)m * total_elems + idx] = FromOracle(seeds[m], idx);
    }
}

// Host launcher sketch (to call from accelerated_solver.cpp's CUDA path):
//
//   const uint32_t total = n * n;                 // 512*512 = 262144
//   dim3 block(256);
//   dim3 grid((total + 255) / 256, num_matrices); // num_matrices = 2*K
//   GenerateBaseMatrixBatchKernel<<<grid, block, 0, stream>>>(d_seeds, d_matrices, total, num_matrices);
//
// Then feed d_matrices straight into the existing device matmul+digest (matmul_accel.cu),
// keeping A,B device-resident — this is the whole point (no host FromSeed, no H2D copy).
//
// Memory: 512*512*4 B = 1 MiB per matrix. A K=16 window = 32 matrices = 32 MiB. Trivial on 32 GB.
//
// VALIDATION GATE before trusting throughput:
//   1. d_matrices[m] (copied back) == CPU FromSeed(seed_m, n), byte-exact, for random seeds.
//   2. End-to-end GPU digest == CPU canonical digest (leave BTX_MATMUL_CPU_CONFIRM=1 on).
// A mismatch only costs self-rejected blocks (node re-checks via CheckProofOfWork), never chain safety.

// SEED DERIVATION (Step 2): seeds come from DeterministicMatMulSeedV2 (pow.cpp:63) =
//   SHA256("BTX_MATMUL_SEED_V2" ‖ hashPrevBlock ‖ height ‖ nVersion ‖ hashMerkleRoot ‖
//          nTime ‖ nBits ‖ nNonce64 ‖ matmul_dim ‖ which)
// Across a nonce window only nNonce64 (and `which`) vary. Precompute the SHA midstate over
// the fixed prefix on host; a small device kernel finishes per (nonce, which). Must match
// HashWriter serialization byte-for-byte (LE ints, 32-byte hashes as stored).
