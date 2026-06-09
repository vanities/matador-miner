// Byte-exact + throughput validation for sha-windowed-scanner.patch.
// ScanOrig = verbatim 0.32.3 (w[64], the consensus reference). ScanWin = windowed (m[16]).
// PASS iff every nonce's sigma is byte-identical between the two — CONSENSUS-CRITICAL:
// re-run this (expect PASS) whenever the patch is re-derived against a new BTX version,
// BEFORE trusting it. The throughput table should show ScanWin ~2x ScanOrig.
//   run:   nvcc -arch=sm_120 -O3 -o sha_test validate-sha-windowed-scanner.cu && ./sha_test
//   ptxas: nvcc -arch=sm_120 -O3 -Xptxas -v -c validate-sha-windowed-scanner.cu  (w[64] 448B -> w[16] 224B frame)
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cuda_runtime.h>

typedef uint32_t Element;
constexpr uint32_t MODULUS = 0x7fffffffU;
constexpr uint32_t ORACLE_THREADS = 256;
struct OracleSeedBytes { uint8_t data[32]; };

// ---- SHA-256 primitives (verbatim 0.32.3) ----
__device__ inline uint32_t RotR(uint32_t x, uint32_t n){ return (x>>n)|(x<<(32U-n)); }
__device__ inline uint32_t ShaCh(uint32_t x,uint32_t y,uint32_t z){ return (x&y)^((~x)&z); }
__device__ inline uint32_t ShaMaj(uint32_t x,uint32_t y,uint32_t z){ return (x&y)^(x&z)^(y&z); }
__device__ inline uint32_t ShaBSig0(uint32_t x){ return RotR(x,2U)^RotR(x,13U)^RotR(x,22U); }
__device__ inline uint32_t ShaBSig1(uint32_t x){ return RotR(x,6U)^RotR(x,11U)^RotR(x,25U); }
__device__ inline uint32_t ShaSSig0(uint32_t x){ return RotR(x,7U)^RotR(x,18U)^(x>>3U); }
__device__ inline uint32_t ShaSSig1(uint32_t x){ return RotR(x,17U)^RotR(x,19U)^(x>>10U); }
__device__ __constant__ uint32_t SHA256_K[64] = {
    0x428a2f98U,0x71374491U,0xb5c0fbcfU,0xe9b5dba5U,0x3956c25bU,0x59f111f1U,0x923f82a4U,0xab1c5ed5U,
    0xd807aa98U,0x12835b01U,0x243185beU,0x550c7dc3U,0x72be5d74U,0x80deb1feU,0x9bdc06a7U,0xc19bf174U,
    0xe49b69c1U,0xefbe4786U,0x0fc19dc6U,0x240ca1ccU,0x2de92c6fU,0x4a7484aaU,0x5cb0a9dcU,0x76f988daU,
    0x983e5152U,0xa831c66dU,0xb00327c8U,0xbf597fc7U,0xc6e00bf3U,0xd5a79147U,0x06ca6351U,0x14292967U,
    0x27b70a85U,0x2e1b2138U,0x4d2c6dfcU,0x53380d13U,0x650a7354U,0x766a0abbU,0x81c2c92eU,0x92722c85U,
    0xa2bfe8a1U,0xa81a664bU,0xc24b8b70U,0xc76c51a3U,0xd192e819U,0xd6990624U,0xf40e3585U,0x106aa070U,
    0x19a4c116U,0x1e376c08U,0x2748774cU,0x34b0bcb5U,0x391c0cb3U,0x4ed8aa4aU,0x5b9cca4fU,0x682e6ff3U,
    0x748f82eeU,0x78a5636fU,0x84c87814U,0x8cc70208U,0x90befffaU,0xa4506cebU,0xbef9a3f7U,0xc67178f2U,
};
__device__ inline void Sha256Init(uint32_t s[8]){
    s[0]=0x6a09e667U;s[1]=0xbb67ae85U;s[2]=0x3c6ef372U;s[3]=0xa54ff53aU;
    s[4]=0x510e527fU;s[5]=0x9b05688cU;s[6]=0x1f83d9abU;s[7]=0x5be0cd19U;
}

// ---- ORIGINAL compress: pre-expand w[16..63] in a 64-word array (the spilling one) ----
__device__ inline void Sha256Compress(uint32_t state[8], uint32_t w[64]){
    for (uint32_t t=16;t<64;++t) w[t]=ShaSSig1(w[t-2])+w[t-7]+ShaSSig0(w[t-15])+w[t-16];
    uint32_t a=state[0],b=state[1],c=state[2],d=state[3],e=state[4],f=state[5],g=state[6],h=state[7];
    for (uint32_t t=0;t<64;++t){
        const uint32_t t1=h+ShaBSig1(e)+ShaCh(e,f,g)+SHA256_K[t]+w[t];
        const uint32_t t2=ShaBSig0(a)+ShaMaj(a,b,c);
        h=g;g=f;f=e;e=d+t1;d=c;c=b;b=a;a=t1+t2;
    }
    state[0]+=a;state[1]+=b;state[2]+=c;state[3]+=d;state[4]+=e;state[5]+=f;state[6]+=g;state[7]+=h;
}
// ---- WINDOWED compress: 16-word sliding schedule, no 64-word array ----
__device__ inline void Sha256CompressW(uint32_t state[8], uint32_t m[16]){
    uint32_t a=state[0],b=state[1],c=state[2],d=state[3],e=state[4],f=state[5],g=state[6],h=state[7];
    #pragma unroll
    for (uint32_t t=0;t<64;++t){
        uint32_t wt;
        if (t<16) wt=m[t];
        else { wt=ShaSSig1(m[(t-2)&15])+m[(t-7)&15]+ShaSSig0(m[(t-15)&15])+m[(t-16)&15]; m[t&15]=wt; }
        const uint32_t t1=h+ShaBSig1(e)+ShaCh(e,f,g)+SHA256_K[t]+wt;
        const uint32_t t2=ShaBSig0(a)+ShaMaj(a,b,c);
        h=g;g=f;f=e;e=d+t1;d=c;c=b;b=a;a=t1+t2;
    }
    state[0]+=a;state[1]+=b;state[2]+=c;state[3]+=d;state[4]+=e;state[5]+=f;state[6]+=g;state[7]+=h;
}

// ---- Sha256Bytes: ORIGINAL (verbatim, builds 16 words, calls w[64] compress) ----
__device__ inline void Sha256Bytes(const uint8_t* message, uint32_t message_len, uint8_t out[32]){
    uint32_t state[8]; Sha256Init(state);
    const uint32_t total_blocks=(message_len+9U+63U)/64U;
    const uint64_t bit_len=(uint64_t)message_len*8U;
    for (uint32_t block=0;block<total_blocks;++block){
        uint32_t w[64]={};
        for (uint32_t word=0;word<16;++word){
            uint32_t packed=0;
            for (uint32_t byte=0;byte<4;++byte){
                const uint32_t mi=block*64U+word*4U+byte; uint8_t value=0;
                if (mi<message_len) value=message[mi];
                else if (mi==message_len) value=0x80U;
                else { const uint32_t ls=total_blocks*64U-8U; if (mi>=ls){ const uint32_t sh=(7U-(mi-ls))*8U; value=(uint8_t)((bit_len>>sh)&0xffU);} }
                packed=(packed<<8U)|value;
            }
            w[word]=packed;
        }
        Sha256Compress(state, w);
    }
    for (uint32_t i=0;i<8;++i){ out[i*4U]=(uint8_t)((state[i]>>24)&0xff); out[i*4U+1]=(uint8_t)((state[i]>>16)&0xff); out[i*4U+2]=(uint8_t)((state[i]>>8)&0xff); out[i*4U+3]=(uint8_t)(state[i]&0xff); }
}
// ---- Sha256Bytes: WINDOWED (identical message build into m[16], windowed compress) ----
__device__ inline void Sha256BytesW(const uint8_t* message, uint32_t message_len, uint8_t out[32]){
    uint32_t state[8]; Sha256Init(state);
    const uint32_t total_blocks=(message_len+9U+63U)/64U;
    const uint64_t bit_len=(uint64_t)message_len*8U;
    for (uint32_t block=0;block<total_blocks;++block){
        uint32_t m[16];
        for (uint32_t word=0;word<16;++word){
            uint32_t packed=0;
            for (uint32_t byte=0;byte<4;++byte){
                const uint32_t mi=block*64U+word*4U+byte; uint8_t value=0;
                if (mi<message_len) value=message[mi];
                else if (mi==message_len) value=0x80U;
                else { const uint32_t ls=total_blocks*64U-8U; if (mi>=ls){ const uint32_t sh=(7U-(mi-ls))*8U; value=(uint8_t)((bit_len>>sh)&0xffU);} }
                packed=(packed<<8U)|value;
            }
            m[word]=packed;
        }
        Sha256CompressW(state, m);
    }
    for (uint32_t i=0;i<8;++i){ out[i*4U]=(uint8_t)((state[i]>>24)&0xff); out[i*4U+1]=(uint8_t)((state[i]>>16)&0xff); out[i*4U+2]=(uint8_t)((state[i]>>8)&0xff); out[i*4U+3]=(uint8_t)(state[i]&0xff); }
}

// ---- Append helpers (verbatim) ----
__device__ inline void AppendByte(uint8_t* m,uint32_t& o,uint8_t v){ m[o++]=v; }
__device__ inline void AppendBytes(uint8_t* m,uint32_t& o,const uint8_t* d,uint32_t s){ for(uint32_t i=0;i<s;++i) m[o++]=d[i]; }
__device__ inline void AppendLE16(uint8_t* m,uint32_t& o,uint16_t v){ AppendByte(m,o,(uint8_t)(v&0xff)); AppendByte(m,o,(uint8_t)((v>>8)&0xff)); }
__device__ inline void AppendLE32(uint8_t* m,uint32_t& o,uint32_t v){ AppendByte(m,o,(uint8_t)(v&0xff)); AppendByte(m,o,(uint8_t)((v>>8)&0xff)); AppendByte(m,o,(uint8_t)((v>>16)&0xff)); AppendByte(m,o,(uint8_t)((v>>24)&0xff)); }
__device__ inline void AppendLE64(uint8_t* m,uint32_t& o,uint64_t v){ for(uint32_t i=0;i<8;++i) AppendByte(m,o,(uint8_t)((v>>(i*8U))&0xff)); }

// seed_v2 + header-hash, templated on the Sha256Bytes flavor via a bool
template<bool WIN>
__device__ inline void SeedV2(const OracleSeedBytes& prev,const OracleSeedBytes& merkle,uint32_t height,uint32_t version,uint32_t time,uint32_t bits,uint64_t nonce,uint16_t dim,uint8_t which,uint8_t out[32]){
    uint8_t msg[110]; uint32_t o=0; const char TAG[]="BTX_MATMUL_SEED_V2";
    AppendByte(msg,o,18U); for(uint32_t i=0;i<18U;++i) AppendByte(msg,o,(uint8_t)TAG[i]);
    AppendBytes(msg,o,prev.data,32U); AppendLE32(msg,o,height); AppendLE32(msg,o,version);
    AppendBytes(msg,o,merkle.data,32U); AppendLE32(msg,o,time); AppendLE32(msg,o,bits);
    AppendLE64(msg,o,nonce); AppendLE16(msg,o,dim); AppendByte(msg,o,which);
    if (WIN) Sha256BytesW(msg,o,out); else Sha256Bytes(msg,o,out);
}
template<bool WIN>
__device__ inline void HeaderHash(uint32_t version,const OracleSeedBytes& prev,const OracleSeedBytes& merkle,uint32_t time,uint32_t bits,uint64_t nonce,uint16_t dim,const uint8_t sa[32],const uint8_t sb[32],uint8_t out[32]){
    uint8_t msg[150]; uint32_t o=0;
    AppendLE32(msg,o,version); AppendBytes(msg,o,prev.data,32U); AppendBytes(msg,o,merkle.data,32U);
    AppendLE32(msg,o,time); AppendLE32(msg,o,bits); AppendLE64(msg,o,nonce); AppendLE16(msg,o,dim);
    AppendBytes(msg,o,sa,32U); AppendBytes(msg,o,sb,32U);
    if (WIN) Sha256BytesW(msg,o,out); else Sha256Bytes(msg,o,out);
}

template<bool WIN>
__global__ void ScanKernel(OracleSeedBytes prev,OracleSeedBytes merkle,uint32_t version,uint32_t height,uint32_t time,uint32_t bits,uint64_t start_nonce,uint16_t dim,uint32_t n,uint8_t* out_sigma){
    const uint32_t gid=blockIdx.x*blockDim.x+threadIdx.x; if (gid>=n) return;
    const uint64_t nonce=start_nonce+(uint64_t)gid;
    uint8_t sa[32],sb[32],hh[32],sigma[32];
    SeedV2<WIN>(prev,merkle,height,version,time,bits,nonce,dim,0U,sa);
    SeedV2<WIN>(prev,merkle,height,version,time,bits,nonce,dim,1U,sb);
    HeaderHash<WIN>(version,prev,merkle,time,bits,nonce,dim,sa,sb,hh);
    if (WIN) Sha256BytesW(hh,32U,sigma); else Sha256Bytes(hh,32U,sigma);
    for (uint32_t i=0;i<32;++i) out_sigma[(size_t)gid*32+i]=sigma[i];
}

int main(){
    const uint32_t N=200000;
    OracleSeedBytes prev,merkle; for(int i=0;i<32;++i){ prev.data[i]=(uint8_t)(i*7+1); merkle.data[i]=(uint8_t)(i*13+5); }
    uint8_t *d_o,*d_w; cudaMalloc(&d_o,(size_t)N*32); cudaMalloc(&d_w,(size_t)N*32);
    const uint32_t blocks=(N+ORACLE_THREADS-1)/ORACLE_THREADS;
    const uint32_t VER=0x20000000U,H=125720U,T=1700000000U,BITS=0x1d185ef7U; const uint64_t SN=42000000ULL; const uint16_t DIM=512U;
    // --- byte-exact ---
    ScanKernel<false><<<blocks,ORACLE_THREADS>>>(prev,merkle,VER,H,T,BITS,SN,DIM,N,d_o);
    ScanKernel<true ><<<blocks,ORACLE_THREADS>>>(prev,merkle,VER,H,T,BITS,SN,DIM,N,d_w);
    cudaError_t e=cudaDeviceSynchronize(); if(e){ printf("CUDA err: %s\n",cudaGetErrorString(e)); return 2; }
    uint8_t *o=(uint8_t*)malloc((size_t)N*32),*w=(uint8_t*)malloc((size_t)N*32);
    cudaMemcpy(o,d_o,(size_t)N*32,cudaMemcpyDeviceToHost); cudaMemcpy(w,d_w,(size_t)N*32,cudaMemcpyDeviceToHost);
    size_t mism=0; for(size_t i=0;i<(size_t)N*32;++i) if(o[i]!=w[i]) ++mism;
    printf("byte-exact: nonces=%u mismatches=%zu -> %s\n",N,mism,mism==0?"PASS":"FAIL");
    if(mism) return 1;
    // --- throughput: orig vs windowed, interleaved rounds (contended w/ live miner; ratio is the signal) ---
    const int ITERS=300;
    cudaEvent_t s,e2; cudaEventCreate(&s); cudaEventCreate(&e2);
    for(int i=0;i<20;++i){ ScanKernel<false><<<blocks,ORACLE_THREADS>>>(prev,merkle,VER,H,T,BITS,SN,DIM,N,d_o); ScanKernel<true><<<blocks,ORACLE_THREADS>>>(prev,merkle,VER,H,T,BITS,SN,DIM,N,d_w);} cudaDeviceSynchronize();
    printf("round   orig(MN/s)   win(MN/s)   speedup\n");
    for(int r=0;r<4;++r){
        cudaEventRecord(s); for(int i=0;i<ITERS;++i) ScanKernel<false><<<blocks,ORACLE_THREADS>>>(prev,merkle,VER,H,T,BITS,SN,DIM,N,d_o); cudaEventRecord(e2); cudaEventSynchronize(e2);
        float mo; cudaEventElapsedTime(&mo,s,e2);
        cudaEventRecord(s); for(int i=0;i<ITERS;++i) ScanKernel<true ><<<blocks,ORACLE_THREADS>>>(prev,merkle,VER,H,T,BITS,SN,DIM,N,d_w); cudaEventRecord(e2); cudaEventSynchronize(e2);
        float mw; cudaEventElapsedTime(&mw,s,e2);
        double no=(double)N*ITERS/(mo/1000.0)/1e6, nw=(double)N*ITERS/(mw/1000.0)/1e6;
        printf("%5d %11.1f %11.1f %+8.1f%%\n", r, no, nw, (nw/no-1.0)*100.0);
    }
    return 0;
}
