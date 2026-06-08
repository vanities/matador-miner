// Milestone-1 validation: GPU base-matrix generator vs CPU from_oracle (python truth).
//
// Goal: prove FromSeedGpu produces a byte-identical matrix to CPU FromSeed, so we can
// safely swap the per-nonce CPU SharedFromSeed for an on-device generator in the v2 solve.
//
// The device SHA-256 + CandidateFromSeedAndIndex / FallbackCandidate / FromOracle below are
// copied VERBATIM from src/cuda/oracle_accel.cu (the consensus GPU oracle). Only the kernel
// GenerateBaseMatrixKernel and the host harness are new.
//
// build+run (on a host with the GPU):
//   docker run --rm --gpus all -v "$PWD":/work nvidia/cuda:12.8.0-cudnn-devel-ubuntu22.04 \
//     bash -c "cd /work && nvcc -O3 -arch=sm_120 validate.cu -o validate && ./validate"

#include <cstdio>
#include <cstdint>
#include <vector>

constexpr uint32_t MODULUS = 0x7FFFFFFFU;   // field::MODULUS (M31 = 2^31-1)

struct OracleSeedBytes { uint8_t data[32]; };

// ================= VERBATIM from oracle_accel.cu (lines 540-723) =================
__device__ inline uint32_t RotR(uint32_t x, uint32_t n) { return (x >> n) | (x << (32U - n)); }
__device__ inline uint32_t ShaCh(uint32_t x, uint32_t y, uint32_t z) { return (x & y) ^ ((~x) & z); }
__device__ inline uint32_t ShaMaj(uint32_t x, uint32_t y, uint32_t z) { return (x & y) ^ (x & z) ^ (y & z); }
__device__ inline uint32_t ShaBSig0(uint32_t x) { return RotR(x, 2U) ^ RotR(x, 13U) ^ RotR(x, 22U); }
__device__ inline uint32_t ShaBSig1(uint32_t x) { return RotR(x, 6U) ^ RotR(x, 11U) ^ RotR(x, 25U); }
__device__ inline uint32_t ShaSSig0(uint32_t x) { return RotR(x, 7U) ^ RotR(x, 18U) ^ (x >> 3U); }
__device__ inline uint32_t ShaSSig1(uint32_t x) { return RotR(x, 17U) ^ RotR(x, 19U) ^ (x >> 10U); }

__device__ __constant__ uint32_t SHA256_K[64] = {
    0x428a2f98U, 0x71374491U, 0xb5c0fbcfU, 0xe9b5dba5U, 0x3956c25bU, 0x59f111f1U, 0x923f82a4U, 0xab1c5ed5U,
    0xd807aa98U, 0x12835b01U, 0x243185beU, 0x550c7dc3U, 0x72be5d74U, 0x80deb1feU, 0x9bdc06a7U, 0xc19bf174U,
    0xe49b69c1U, 0xefbe4786U, 0x0fc19dc6U, 0x240ca1ccU, 0x2de92c6fU, 0x4a7484aaU, 0x5cb0a9dcU, 0x76f988daU,
    0x983e5152U, 0xa831c66dU, 0xb00327c8U, 0xbf597fc7U, 0xc6e00bf3U, 0xd5a79147U, 0x06ca6351U, 0x14292967U,
    0x27b70a85U, 0x2e1b2138U, 0x4d2c6dfcU, 0x53380d13U, 0x650a7354U, 0x766a0abbU, 0x81c2c92eU, 0x92722c85U,
    0xa2bfe8a1U, 0xa81a664bU, 0xc24b8b70U, 0xc76c51a3U, 0xd192e819U, 0xd6990624U, 0xf40e3585U, 0x106aa070U,
    0x19a4c116U, 0x1e376c08U, 0x2748774cU, 0x34b0bcb5U, 0x391c0cb3U, 0x4ed8aa4aU, 0x5b9cca4fU, 0x682e6ff3U,
    0x748f82eeU, 0x78a5636fU, 0x84c87814U, 0x8cc70208U, 0x90befffaU, 0xa4506cebU, 0xbef9a3f7U, 0xc67178f2U,
};

__device__ inline void Sha256Init(uint32_t state[8]) {
    state[0] = 0x6a09e667U; state[1] = 0xbb67ae85U; state[2] = 0x3c6ef372U; state[3] = 0xa54ff53aU;
    state[4] = 0x510e527fU; state[5] = 0x9b05688cU; state[6] = 0x1f83d9abU; state[7] = 0x5be0cd19U;
}

__device__ inline void SetByte(uint32_t w[64], uint32_t offset, uint32_t byte) {
    const uint32_t word_index = offset >> 2U;
    const uint32_t shift = (3U - (offset & 3U)) * 8U;
    w[word_index] |= (byte & 0xffU) << shift;
}

__device__ inline uint32_t Bswap32(uint32_t x) {
    return ((x & 0x000000ffU) << 24U) | ((x & 0x0000ff00U) << 8U) |
           ((x & 0x00ff0000U) >> 8U) | ((x & 0xff000000U) >> 24U);
}

__device__ inline void Sha256Compress(uint32_t state[8], uint32_t w[64]) {
    for (uint32_t t = 16; t < 64; ++t)
        w[t] = ShaSSig1(w[t - 2]) + w[t - 7] + ShaSSig0(w[t - 15]) + w[t - 16];
    uint32_t a = state[0], b = state[1], c = state[2], d = state[3];
    uint32_t e = state[4], f = state[5], g = state[6], h = state[7];
    for (uint32_t t = 0; t < 64; ++t) {
        const uint32_t t1 = h + ShaBSig1(e) + ShaCh(e, f, g) + SHA256_K[t] + w[t];
        const uint32_t t2 = ShaBSig0(a) + ShaMaj(a, b, c);
        h = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
    }
    state[0] += a; state[1] += b; state[2] += c; state[3] += d;
    state[4] += e; state[5] += f; state[6] += g; state[7] += h;
}

__device__ inline uint32_t CandidateFromSeedAndIndex(const OracleSeedBytes& seed, uint32_t index,
                                                     bool with_retry, uint32_t retry) {
    uint32_t w[64] = {};
    for (uint32_t i = 0; i < 32; ++i) SetByte(w, i, seed.data[31U - i]);
    SetByte(w, 32U, index & 0xffU);
    SetByte(w, 33U, (index >> 8U) & 0xffU);
    SetByte(w, 34U, (index >> 16U) & 0xffU);
    SetByte(w, 35U, (index >> 24U) & 0xffU);
    uint32_t message_len = 36U;
    if (with_retry) {
        SetByte(w, 36U, retry & 0xffU);
        SetByte(w, 37U, (retry >> 8U) & 0xffU);
        SetByte(w, 38U, (retry >> 16U) & 0xffU);
        SetByte(w, 39U, (retry >> 24U) & 0xffU);
        message_len = 40U;
    }
    SetByte(w, message_len, 0x80U);
    w[15] = message_len * 8U;
    uint32_t state[8];
    Sha256Init(state);
    Sha256Compress(state, w);
    return Bswap32(state[0]) & MODULUS;
}

__device__ inline uint32_t FallbackCandidate(const OracleSeedBytes& seed, uint32_t index) {
    uint32_t w[64] = {};
    for (uint32_t i = 0; i < 32; ++i) SetByte(w, i, seed.data[31U - i]);
    SetByte(w, 32U, index & 0xffU);
    SetByte(w, 33U, (index >> 8U) & 0xffU);
    SetByte(w, 34U, (index >> 16U) & 0xffU);
    SetByte(w, 35U, (index >> 24U) & 0xffU);
    constexpr uint8_t fallback_tag[15] = {'o','r','a','c','l','e','-','f','a','l','l','b','a','c','k'};
    for (uint32_t i = 0; i < 15; ++i) SetByte(w, 36U + i, fallback_tag[i]);
    SetByte(w, 51U, 0x80U);
    w[15] = 51U * 8U;
    uint32_t state[8];
    Sha256Init(state);
    Sha256Compress(state, w);
    return Bswap32(state[0]) % MODULUS;
}

__device__ inline uint32_t FromOracle(const OracleSeedBytes& seed, uint32_t index) {
    for (uint32_t retry = 0; retry < 256; ++retry) {
        const uint32_t candidate = retry == 0
            ? CandidateFromSeedAndIndex(seed, index, false, 0U)
            : CandidateFromSeedAndIndex(seed, index, true, retry);
        if (candidate < MODULUS) return candidate;
    }
    return FallbackCandidate(seed, index);
}
// ================= END VERBATIM =================

// ===== OPT2: windowed SHA-256 (16-word schedule vs 64) — same output, far fewer registers =====
__device__ inline void Sha256CompressWindowed(uint32_t state[8], uint32_t m[16]) {
    uint32_t a=state[0],b=state[1],c=state[2],d=state[3],e=state[4],f=state[5],g=state[6],h=state[7];
    #pragma unroll
    for (uint32_t t = 0; t < 64; ++t) {
        uint32_t wt;
        if (t < 16) { wt = m[t]; }
        else { wt = ShaSSig1(m[(t-2)&15]) + m[(t-7)&15] + ShaSSig0(m[(t-15)&15]) + m[(t-16)&15]; m[t&15] = wt; }
        const uint32_t t1 = h + ShaBSig1(e) + ShaCh(e,f,g) + SHA256_K[t] + wt;
        const uint32_t t2 = ShaBSig0(a) + ShaMaj(a,b,c);
        h=g; g=f; f=e; e=d+t1; d=c; c=b; b=a; a=t1+t2;
    }
    state[0]+=a; state[1]+=b; state[2]+=c; state[3]+=d; state[4]+=e; state[5]+=f; state[6]+=g; state[7]+=h;
}
__device__ inline uint32_t CandidateOpt(const OracleSeedBytes& seed, uint32_t index, bool with_retry, uint32_t retry) {
    uint32_t w[16] = {};
    for (uint32_t i = 0; i < 32; ++i) SetByte(w, i, seed.data[31U - i]);
    SetByte(w, 32U, index & 0xffU); SetByte(w, 33U, (index>>8)&0xffU); SetByte(w, 34U, (index>>16)&0xffU); SetByte(w, 35U, (index>>24)&0xffU);
    uint32_t message_len = 36U;
    if (with_retry) { SetByte(w,36U,retry&0xffU); SetByte(w,37U,(retry>>8)&0xffU); SetByte(w,38U,(retry>>16)&0xffU); SetByte(w,39U,(retry>>24)&0xffU); message_len=40U; }
    SetByte(w, message_len, 0x80U);
    w[15] = message_len * 8U;
    uint32_t state[8]; Sha256Init(state); Sha256CompressWindowed(state, w);
    return Bswap32(state[0]) & MODULUS;
}
__device__ inline uint32_t FallbackCandidateOpt(const OracleSeedBytes& seed, uint32_t index) {
    uint32_t w[16] = {};
    for (uint32_t i = 0; i < 32; ++i) SetByte(w, i, seed.data[31U - i]);
    SetByte(w, 32U, index & 0xffU); SetByte(w, 33U, (index>>8)&0xffU); SetByte(w, 34U, (index>>16)&0xffU); SetByte(w, 35U, (index>>24)&0xffU);
    constexpr uint8_t tag[15] = {'o','r','a','c','l','e','-','f','a','l','l','b','a','c','k'};
    for (uint32_t i = 0; i < 15; ++i) SetByte(w, 36U + i, tag[i]);
    SetByte(w, 51U, 0x80U); w[15] = 51U * 8U;
    uint32_t state[8]; Sha256Init(state); Sha256CompressWindowed(state, w);
    return Bswap32(state[0]) % MODULUS;
}
__device__ inline uint32_t FromOracleOpt(const OracleSeedBytes& seed, uint32_t index) {
    for (uint32_t retry = 0; retry < 256; ++retry) {
        const uint32_t candidate = retry==0 ? CandidateOpt(seed,index,false,0U) : CandidateOpt(seed,index,true,retry);
        if (candidate < MODULUS) return candidate;
    }
    return FallbackCandidateOpt(seed, index);
}
__global__ void GenerateBaseMatrixKernelOpt(OracleSeedBytes seed, uint32_t* __restrict__ out, uint32_t total) {
    const uint32_t idx = blockIdx.x*blockDim.x+threadIdx.x;
    if (idx < total) out[idx] = FromOracleOpt(seed, idx);
}

// NEW: mirrors CPU FromSeed (matrix.cpp:491) — row-major out[idx] = from_oracle(seed, idx).
__global__ void GenerateBaseMatrixKernel(OracleSeedBytes seed, uint32_t* __restrict__ out, uint32_t total) {
    const uint32_t idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < total) out[idx] = FromOracle(seed, idx);
}

// OPT #1: generate A and B in ONE launch (mirrors btxchain's GenerateOracleNoiseKernel, which
// does 4 matrices/launch). One thread does both from_oracle calls at the same index.
__global__ void GenerateBaseMatrixPairKernel(OracleSeedBytes sa, OracleSeedBytes sb,
                                             uint32_t* __restrict__ a, uint32_t* __restrict__ b,
                                             uint32_t total) {
    const uint32_t idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < total) { a[idx] = FromOracle(sa, idx); b[idx] = FromOracle(sb, idx); }
}

#define CK(call) do { cudaError_t e=(call); if(e!=cudaSuccess){ \
    printf("CUDA error %s at %s:%d\n", cudaGetErrorString(e), __FILE__, __LINE__); return 2; } } while(0)

int main() {
    const uint32_t n = 512, total = n * n;
    OracleSeedBytes seed;
    for (int i = 0; i < 32; ++i) seed.data[i] = (uint8_t)i;   // bytes 0..31, same as gen_truth.py

    uint32_t* d_out = nullptr;
    CK(cudaMalloc(&d_out, total * sizeof(uint32_t)));
    dim3 block(256), grid((total + 255) / 256);
    GenerateBaseMatrixKernel<<<grid, block>>>(seed, d_out, total);
    CK(cudaGetLastError());
    CK(cudaDeviceSynchronize());

    std::vector<uint32_t> gpu(total);
    CK(cudaMemcpy(gpu.data(), d_out, total * sizeof(uint32_t), cudaMemcpyDeviceToHost));
    cudaFree(d_out);

    FILE* f = fopen("truth.bin", "rb");
    if (!f) { printf("missing truth.bin (run gen_truth.py first)\n"); return 2; }
    std::vector<uint32_t> truth(total);
    size_t rd = fread(truth.data(), sizeof(uint32_t), total, f);
    fclose(f);
    if (rd != total) { printf("truth.bin short read: %zu/%u\n", rd, total); return 2; }

    uint32_t mism = 0, first = 0;
    for (uint32_t i = 0; i < total; ++i)
        if (gpu[i] != truth[i]) { if (!mism) first = i; ++mism; }

    printf("gpu anchors [0,1,2,100,last] = %u %u %u %u %u\n",
           gpu[0], gpu[1], gpu[2], gpu[100], gpu[total - 1]);
    if (mism == 0) {
        printf("RESULT: ALL %u ELEMENTS MATCH (GPU FromSeed == CPU from_oracle, byte-exact)\n", total);
        // ---- benchmark: GPU matrix-gen throughput (this was the CPU bottleneck) ----
        uint32_t* d_b = nullptr;
        CK(cudaMalloc(&d_b, total * sizeof(uint32_t)));
        const int iters = 5000;
        cudaEvent_t t0, t1; cudaEventCreate(&t0); cudaEventCreate(&t1);
        GenerateBaseMatrixKernel<<<grid, block>>>(seed, d_b, total); // warmup
        CK(cudaDeviceSynchronize());
        cudaEventRecord(t0);
        for (int it = 0; it < iters; ++it) { seed.data[0] = (uint8_t)it;
            GenerateBaseMatrixKernel<<<grid, block>>>(seed, d_b, total); }
        cudaEventRecord(t1); CK(cudaEventSynchronize(t1));
        float ms = 0; cudaEventElapsedTime(&ms, t0, t1);
        double mps = iters / (ms / 1000.0);
        printf("BENCH: %d matrices in %.1f ms = %.0f matrices/s => ~%.0f nonces/s ceiling "
               "from matrix-gen (2 matrices/nonce)\n", iters, ms, mps, mps / 2.0);

        // ---- OPT #1 head-to-head: separate (2 launches+2 syncs) vs combined (1 launch+1 sync),
        //      per-iteration sync to match the live solver's blocking per-worker pattern ----
        uint32_t* d_a2 = nullptr;
        CK(cudaMalloc(&d_a2, total * sizeof(uint32_t)));
        OracleSeedBytes sa = seed, sb = seed; sb.data[0] ^= 0xFFu;
        const int pairs = 3000;
        GenerateBaseMatrixPairKernel<<<grid, block>>>(sa, sb, d_a2, d_b, total); CK(cudaDeviceSynchronize());
        cudaEventRecord(t0);
        for (int it = 0; it < pairs; ++it) { sa.data[1] = (uint8_t)it; sb.data[1] = (uint8_t)it;
            GenerateBaseMatrixKernel<<<grid, block>>>(sa, d_a2, total); cudaStreamSynchronize(0);
            GenerateBaseMatrixKernel<<<grid, block>>>(sb, d_b,  total); cudaStreamSynchronize(0); }
        cudaEventRecord(t1); CK(cudaEventSynchronize(t1));
        float ms_sep = 0; cudaEventElapsedTime(&ms_sep, t0, t1);
        cudaEventRecord(t0);
        for (int it = 0; it < pairs; ++it) { sa.data[1] = (uint8_t)it; sb.data[1] = (uint8_t)it;
            GenerateBaseMatrixPairKernel<<<grid, block>>>(sa, sb, d_a2, d_b, total); cudaStreamSynchronize(0); }
        cudaEventRecord(t1); CK(cudaEventSynchronize(t1));
        float ms_comb = 0; cudaEventElapsedTime(&ms_comb, t0, t1);
        printf("OPT1 SEPARATE (2 launch+2 sync/pair): %d pairs in %.1f ms = %.0f pairs/s\n",
               pairs, ms_sep, pairs / (ms_sep / 1000.0));
        printf("OPT1 COMBINED (1 launch+1 sync/pair): %d pairs in %.1f ms = %.0f pairs/s  => %+.1f%%\n",
               pairs, ms_comb, pairs / (ms_comb / 1000.0), 100.0 * (ms_sep / ms_comb - 1.0));

        // ---- OPT2: windowed-SHA kernel — validate byte-exact + benchmark vs current (w64) ----
        for (int i = 0; i < 32; ++i) seed.data[i] = (uint8_t)i;   // reset to the validated seed (0..31)
        GenerateBaseMatrixKernelOpt<<<grid, block>>>(seed, d_a2, total); CK(cudaDeviceSynchronize());
        std::vector<uint32_t> optout(total);
        CK(cudaMemcpy(optout.data(), d_a2, total * sizeof(uint32_t), cudaMemcpyDeviceToHost));
        uint32_t omis = 0; for (uint32_t i = 0; i < total; ++i) if (optout[i] != truth[i]) ++omis;
        printf("OPT2 windowed-SHA correctness: %s (%u mismatches)\n", omis == 0 ? "BYTE-EXACT" : "FAIL", omis);
        if (omis == 0) {
            seed.data[1] = 0;
            cudaEventRecord(t0);
            for (int it = 0; it < iters; ++it) { seed.data[0] = (uint8_t)it; GenerateBaseMatrixKernel<<<grid, block>>>(seed, d_a2, total); }
            cudaEventRecord(t1); CK(cudaEventSynchronize(t1)); float msc = 0; cudaEventElapsedTime(&msc, t0, t1);
            cudaEventRecord(t0);
            for (int it = 0; it < iters; ++it) { seed.data[0] = (uint8_t)it; GenerateBaseMatrixKernelOpt<<<grid, block>>>(seed, d_a2, total); }
            cudaEventRecord(t1); CK(cudaEventSynchronize(t1)); float mso = 0; cudaEventElapsedTime(&mso, t0, t1);
            printf("OPT2 CURRENT(w64): %.0f matrices/s | WINDOWED(w16): %.0f matrices/s  => %+.1f%%\n",
                   iters / (msc / 1000.0), iters / (mso / 1000.0), 100.0 * (msc / mso - 1.0));
        }
        cudaFree(d_a2);
        cudaFree(d_b);
        return 0;
    }
    printf("RESULT: %u/%u MISMATCH (first idx %u: gpu=%u truth=%u)\n",
           mism, total, first, gpu[first], truth[first]);
    return 1;
}
