// Byte-exact + throughput validation for the two matmul_accel.cu patches:
//   sha-windowed-matrixgen.patch  - windowed SHA in the per-candidate matrix gen
//   fused-single-reduction.patch  - single block reduction in non-prefix fused kernel
// Orig* = verbatim 0.32.3 (the consensus reference). New* = patched logic.
// PASS iff outputs are byte-identical - CONSENSUS-CRITICAL: re-run (expect PASS)
// whenever the patches are re-derived against a new BTX version, BEFORE trusting them.
// The fused test additionally cross-checks BOTH kernels against a CPU reference.
//   run:   nvcc -arch=sm_120 -O3 -o matmul_test validate-matmul-patches.cu && ./matmul_test
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <cuda_runtime.h>

typedef uint32_t Element;
constexpr uint32_t MODULUS = 0x7fffffffU;
constexpr uint32_t REDUCE_INTERVAL{4};
constexpr uint32_t MAX_BLOCK_THREADS{256};
constexpr uint32_t WORKSPACE_THREADS{256};
struct DeviceSeedBytes { uint8_t data[32]; };

#define CK(x) do{ cudaError_t _e=(x); if(_e){ printf("CUDA err %s @%d\n",cudaGetErrorString(_e),__LINE__); exit(2);} }while(0)

// ---- field + SHA primitives (verbatim 0.32.3 matmul_accel.cu) ----
__host__ __device__ __forceinline__ Element Reduce64(uint64_t value){
    const uint64_t fold1=(value&(uint64_t)MODULUS)+(value>>31);
    const uint32_t lo=(uint32_t)(fold1&MODULUS); const uint32_t hi=(uint32_t)(fold1>>31);
    uint32_t result=lo+hi; const uint32_t ge=(uint32_t)(-(int32_t)(result>=MODULUS));
    result-=(MODULUS&ge); return result;
}
__host__ __device__ __forceinline__ Element FieldAdd(Element a,Element b){ uint32_t s=a+b; if(s>=MODULUS)s-=MODULUS; return s; }
__host__ __device__ __forceinline__ Element FieldMul(Element a,Element b){ return Reduce64((uint64_t)a*(uint64_t)b); }
__device__ __forceinline__ uint32_t RotR(uint32_t x,uint32_t n){ return (x>>n)|(x<<(32U-n)); }
__device__ __forceinline__ uint32_t ShaCh(uint32_t x,uint32_t y,uint32_t z){ return (x&y)^((~x)&z); }
__device__ __forceinline__ uint32_t ShaMaj(uint32_t x,uint32_t y,uint32_t z){ return (x&y)^(x&z)^(y&z); }
__device__ __forceinline__ uint32_t ShaBSig0(uint32_t x){ return RotR(x,2U)^RotR(x,13U)^RotR(x,22U); }
__device__ __forceinline__ uint32_t ShaBSig1(uint32_t x){ return RotR(x,6U)^RotR(x,11U)^RotR(x,25U); }
__device__ __forceinline__ uint32_t ShaSSig0(uint32_t x){ return RotR(x,7U)^RotR(x,18U)^(x>>3U); }
__device__ __forceinline__ uint32_t ShaSSig1(uint32_t x){ return RotR(x,17U)^RotR(x,19U)^(x>>10U); }
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
__device__ __forceinline__ void SetShaByte(uint32_t* w,uint32_t offset,uint32_t byte){
    const uint32_t wi=offset>>2U; const uint32_t sh=(3U-(offset&3U))*8U; w[wi]|=(byte&0xffU)<<sh;
}
// ORIGINAL compress (w[64] pre-expansion)
__device__ inline void Sha256CompressO(uint32_t state[8],uint32_t w[64]){
    for(uint32_t t=16;t<64;++t) w[t]=ShaSSig1(w[t-2])+w[t-7]+ShaSSig0(w[t-15])+w[t-16];
    uint32_t a=state[0],b=state[1],c=state[2],d=state[3],e=state[4],f=state[5],g=state[6],h=state[7];
    for(uint32_t t=0;t<64;++t){
        const uint32_t t1=h+ShaBSig1(e)+ShaCh(e,f,g)+SHA256_K[t]+w[t];
        const uint32_t t2=ShaBSig0(a)+ShaMaj(a,b,c);
        h=g;g=f;f=e;e=d+t1;d=c;c=b;b=a;a=t1+t2;
    }
    state[0]+=a;state[1]+=b;state[2]+=c;state[3]+=d;state[4]+=e;state[5]+=f;state[6]+=g;state[7]+=h;
}
// WINDOWED compress (patched)
__device__ inline void Sha256CompressW(uint32_t state[8],uint32_t w[16]){
    uint32_t a=state[0],b=state[1],c=state[2],d=state[3],e=state[4],f=state[5],g=state[6],h=state[7];
    #pragma unroll
    for(uint32_t t=0;t<64;++t){
        uint32_t wt;
        if(t<16) wt=w[t];
        else { wt=ShaSSig1(w[(t-2)&15U])+w[(t-7)&15U]+ShaSSig0(w[(t-15)&15U])+w[(t-16)&15U]; w[t&15U]=wt; }
        const uint32_t t1=h+ShaBSig1(e)+ShaCh(e,f,g)+SHA256_K[t]+wt;
        const uint32_t t2=ShaBSig0(a)+ShaMaj(a,b,c);
        h=g;g=f;f=e;e=d+t1;d=c;c=b;b=a;a=t1+t2;
    }
    state[0]+=a;state[1]+=b;state[2]+=c;state[3]+=d;state[4]+=e;state[5]+=f;state[6]+=g;state[7]+=h;
}
__device__ __forceinline__ uint32_t Bswap32(uint32_t x){
    return ((x&0x000000ffU)<<24U)|((x&0x0000ff00U)<<8U)|((x&0x00ff0000U)>>8U)|((x&0xff000000U)>>24U);
}

// ---- CandidateFromSeedAndIndex / FallbackCandidate / FromOracle, orig vs win ----
template<bool WIN>
__device__ inline uint32_t Candidate(const DeviceSeedBytes& seed,uint32_t index,bool with_retry,uint32_t retry){
    uint32_t w[WIN?16:64] = {};
    for(uint32_t i=0;i<32;++i) SetShaByte(w,i,seed.data[31U-i]);
    SetShaByte(w,32U,index&0xffU); SetShaByte(w,33U,(index>>8U)&0xffU);
    SetShaByte(w,34U,(index>>16U)&0xffU); SetShaByte(w,35U,(index>>24U)&0xffU);
    uint32_t message_len=36U;
    if(with_retry){
        SetShaByte(w,36U,retry&0xffU); SetShaByte(w,37U,(retry>>8U)&0xffU);
        SetShaByte(w,38U,(retry>>16U)&0xffU); SetShaByte(w,39U,(retry>>24U)&0xffU);
        message_len=40U;
    }
    SetShaByte(w,message_len,0x80U); w[15]=message_len*8U;
    uint32_t state[8]; Sha256Init(state);
    if(WIN) Sha256CompressW(state,w); else Sha256CompressO(state,w);
    return Bswap32(state[0])&MODULUS;
}
template<bool WIN>
__device__ inline uint32_t Fallback(const DeviceSeedBytes& seed,uint32_t index){
    uint32_t w[WIN?16:64] = {};
    for(uint32_t i=0;i<32;++i) SetShaByte(w,i,seed.data[31U-i]);
    SetShaByte(w,32U,index&0xffU); SetShaByte(w,33U,(index>>8U)&0xffU);
    SetShaByte(w,34U,(index>>16U)&0xffU); SetShaByte(w,35U,(index>>24U)&0xffU);
    constexpr uint8_t tag[15]={'o','r','a','c','l','e','-','f','a','l','l','b','a','c','k'};
    for(uint32_t i=0;i<15;++i) SetShaByte(w,36U+i,tag[i]);
    SetShaByte(w,51U,0x80U); w[15]=51U*8U;
    uint32_t state[8]; Sha256Init(state);
    if(WIN) Sha256CompressW(state,w); else Sha256CompressO(state,w);
    return Bswap32(state[0])%MODULUS;
}
template<bool WIN>
__device__ inline uint32_t FromOracle(const DeviceSeedBytes& seed,uint32_t index){
    for(uint32_t retry=0;retry<256;++retry){
        const uint32_t c = retry==0 ? Candidate<WIN>(seed,index,false,0U) : Candidate<WIN>(seed,index,true,retry);
        if(c<MODULUS) return c;
    }
    return Fallback<WIN>(seed,index);
}

// GenerateBaseMatrixFromSeedBatchKernel (verbatim structure), orig vs win
template<bool WIN>
__global__ void GenKernel(const DeviceSeedBytes* seeds,size_t total,uint32_t matrix_elements,Element* out){
    const size_t gid=(size_t)blockIdx.x*blockDim.x+threadIdx.x; if(gid>=total) return;
    const uint32_t batch=(uint32_t)(gid/matrix_elements); const uint32_t local=(uint32_t)(gid%matrix_elements);
    out[gid]=FromOracle<WIN>(seeds[batch],local);
}

// ---- matrixgen-seed-midstate.patch: 2-kernel form (precompute + scalar-load gen) ----
__global__ void PrecomputeMidstatesK(const DeviceSeedBytes* seeds,uint32_t n_seeds,uint32_t* out){
    uint32_t i=blockIdx.x*blockDim.x+threadIdx.x; if(i>=n_seeds) return;
    uint32_t w[8]={}; for(uint32_t k=0;k<32;++k) SetShaByte(w,k,seeds[i].data[31U-k]);
    uint32_t a=0x6a09e667U,b=0xbb67ae85U,c=0x3c6ef372U,d=0xa54ff53aU,e=0x510e527fU,f=0x9b05688cU,g=0x1f83d9abU,h=0x5be0cd19U;
    for(uint32_t t=0;t<8;++t){ uint32_t t1=h+ShaBSig1(e)+ShaCh(e,f,g)+SHA256_K[t]+w[t]; uint32_t t2=ShaBSig0(a)+ShaMaj(a,b,c); h=g;g=f;f=e;e=d+t1;d=c;c=b;b=a;a=t1+t2; }
    uint32_t* o=out+(size_t)i*16U;
    o[0]=w[0];o[1]=w[1];o[2]=w[2];o[3]=w[3];o[4]=w[4];o[5]=w[5];o[6]=w[6];o[7]=w[7];
    o[8]=a;o[9]=b;o[10]=c;o[11]=d;o[12]=e;o[13]=f;o[14]=g;o[15]=h;
}
__device__ inline uint32_t CandMidScalars(const uint32_t* mb,uint32_t index){
    uint32_t w[16]; w[0]=mb[0];w[1]=mb[1];w[2]=mb[2];w[3]=mb[3];w[4]=mb[4];w[5]=mb[5];w[6]=mb[6];w[7]=mb[7];
    for(uint32_t i=8;i<16;++i) w[i]=0U;
    SetShaByte(w,32U,index&0xffU);SetShaByte(w,33U,(index>>8U)&0xffU);SetShaByte(w,34U,(index>>16U)&0xffU);SetShaByte(w,35U,(index>>24U)&0xffU);
    SetShaByte(w,36U,0x80U); w[15]=36U*8U;
    uint32_t a=mb[8],b=mb[9],c=mb[10],d=mb[11],e=mb[12],f=mb[13],g=mb[14],h=mb[15];
    for(uint32_t t=8;t<64;++t){ uint32_t wt; if(t<16) wt=w[t]; else { wt=ShaSSig1(w[(t-2)&15U])+w[(t-7)&15U]+ShaSSig0(w[(t-15)&15U])+w[(t-16)&15U]; w[t&15U]=wt; } uint32_t t1=h+ShaBSig1(e)+ShaCh(e,f,g)+SHA256_K[t]+wt; uint32_t t2=ShaBSig0(a)+ShaMaj(a,b,c); h=g;g=f;f=e;e=d+t1;d=c;c=b;b=a;a=t1+t2; }
    return Bswap32(0x6a09e667U+a)&MODULUS;
}
__global__ void GenKernelMid2(const DeviceSeedBytes* seeds,const uint32_t* midbuf,size_t total,uint32_t matrix_elements,Element* out){
    const size_t gid=(size_t)blockIdx.x*blockDim.x+threadIdx.x; if(gid>=total) return;
    const uint32_t batch=(uint32_t)(gid/matrix_elements); const uint32_t local=(uint32_t)(gid%matrix_elements);
    const uint32_t* mb=midbuf+(size_t)batch*16U;
    uint32_t cand=CandMidScalars(mb,local);
    out[gid] = cand<MODULUS ? cand : FromOracle<true>(seeds[batch],local);
}
// Edge paths (never hit naturally; the patch touched them, so prove them too)
template<bool WIN>
__global__ void EdgeKernel(const DeviceSeedBytes* seeds,uint32_t n_seeds,uint32_t n_idx,uint32_t* out){
    const uint32_t gid=blockIdx.x*blockDim.x+threadIdx.x; if(gid>=n_seeds*n_idx) return;
    const DeviceSeedBytes& s=seeds[gid/n_idx]; const uint32_t idx=gid%n_idx;
    uint32_t acc=0x811c9dc5U;
    for(uint32_t retry=1;retry<=4;++retry) acc=(acc*0x01000193U)^Candidate<WIN>(s,idx,true,retry);
    acc=(acc*0x01000193U)^Fallback<WIN>(s,idx);
    out[gid]=acc;
}

// ---- block reduction (verbatim) ----
__device__ __forceinline__ void ReducePartialsInPlace(Element* partials,uint32_t tid){
    for(uint32_t stride=blockDim.x/2;stride>32;stride>>=1){
        if(tid<stride) partials[tid]=FieldAdd(partials[tid],partials[tid+stride]);
        __syncthreads();
    }
    if(tid<32){
        const uint32_t warp_lanes=blockDim.x<32?blockDim.x:32U; const uint32_t lane=tid&31U;
        Element value=partials[tid];
        if(blockDim.x>=64) value=FieldAdd(value,partials[tid+32]);
        const unsigned warp_mask=__activemask();
        for(uint32_t offset=warp_lanes/2;offset>0;offset>>=1){
            const Element other=__shfl_down_sync(warp_mask,value,offset);
            if(lane+offset<warp_lanes) value=FieldAdd(value,other);
        }
        if(tid==0) partials[0]=value;
    }
}

// ---- fused kernel: ORIGINAL non-prefix (per-ell reduction, verbatim 0.32.3) ----
__global__ void FusedOrig(const Element* __restrict__ A,const Element* __restrict__ B,const Element* __restrict__ comp,
                          uint32_t n,uint32_t bs,uint32_t bpa,uint32_t pcpr,uint32_t wpr,uint32_t me,uint32_t ce,Element* __restrict__ out){
    __shared__ Element partials[MAX_BLOCK_THREADS];
    const uint32_t pair=blockIdx.x; const uint32_t batch=pair/pcpr; const uint32_t lp=pair%pcpr;
    const uint32_t j=lp%bpa; const uint32_t i=lp/bpa; const uint32_t tid=threadIdx.x;
    const uint32_t at=bs*bs;
    const Element* ma=A+(size_t)batch*me; const Element* mb=B+(size_t)batch*me; const Element* cv=comp+(size_t)batch*ce;
    const uint32_t oo=batch*wpr+lp;
    const bool active=tid<at;
    const uint32_t x=active?(tid/bs):0; const uint32_t y=active?(tid%bs):0;
    const uint32_t row=i*bs+x; const uint32_t col=j*bs+y; const size_t ro=(size_t)row*n;
    const Element cc=active?cv[tid]:0;
    Element rt{0};
    for(uint32_t ell=0;ell<bpa;++ell){
        Element partial{0};
        if(active){
            const uint32_t mbase=ell*bs; uint64_t acc{0}; uint32_t pending{0};
            for(uint32_t k=0;k<bs;++k){
                acc+=(uint64_t)ma[ro+(mbase+k)]*mb[(size_t)(mbase+k)*n+col];
                if(++pending==REDUCE_INTERVAL){ acc=Reduce64(acc); pending=0; }
            }
            partial=FieldMul(Reduce64(acc),cc);
        }
        partials[tid]=partial; __syncthreads();
        ReducePartialsInPlace(partials,tid);
        if(tid==0) rt=FieldAdd(rt,partials[0]);
        __syncthreads();
    }
    if(tid==0) out[oo]=rt;
}
// ---- fused kernel: NEW non-prefix (single reduction, the patched fast path) ----
__global__ void FusedNew(const Element* __restrict__ A,const Element* __restrict__ B,const Element* __restrict__ comp,
                         uint32_t n,uint32_t bs,uint32_t bpa,uint32_t pcpr,uint32_t wpr,uint32_t me,uint32_t ce,Element* __restrict__ out){
    __shared__ Element partials[MAX_BLOCK_THREADS];
    const uint32_t pair=blockIdx.x; const uint32_t batch=pair/pcpr; const uint32_t lp=pair%pcpr;
    const uint32_t j=lp%bpa; const uint32_t i=lp/bpa; const uint32_t tid=threadIdx.x;
    const uint32_t at=bs*bs;
    const Element* ma=A+(size_t)batch*me; const Element* mb=B+(size_t)batch*me; const Element* cv=comp+(size_t)batch*ce;
    const uint32_t oo=batch*wpr+lp;
    const bool active=tid<at;
    const uint32_t x=active?(tid/bs):0; const uint32_t y=active?(tid%bs):0;
    const uint32_t row=i*bs+x; const uint32_t col=j*bs+y; const size_t ro=(size_t)row*n;
    const Element cc=active?cv[tid]:0;
    Element rt{0};
    if(active){
        uint64_t acc{0}; uint32_t pending{0};
        for(uint32_t m=0;m<n;++m){
            acc+=(uint64_t)ma[ro+m]*mb[(size_t)m*n+col];
            if(++pending==REDUCE_INTERVAL){ acc=Reduce64(acc); pending=0; }
        }
        rt=FieldMul(Reduce64(acc),cc);
    }
    partials[tid]=rt; __syncthreads();
    ReducePartialsInPlace(partials,tid);
    if(tid==0) out[oo]=partials[0];
}

// ---- factored compression: D once per request, then warp-per-word (the patched fast path) ----
__global__ void FactoredRhs(const Element* __restrict__ B,const Element* __restrict__ comp,
                            uint32_t n,uint32_t bs,size_t total_rhs,uint32_t re,uint32_t me,uint32_t ce,Element* __restrict__ rhs){
    const size_t gid=(size_t)blockIdx.x*blockDim.x+threadIdx.x; if(gid>=total_rhs) return;
    const uint32_t batch=(uint32_t)(gid/re); const uint32_t local=(uint32_t)(gid%re);
    const uint32_t m=local%n; const uint32_t jx=local/n; const uint32_t x=jx%bs; const uint32_t j=jx/bs;
    const Element* b_row=B+(size_t)batch*me+(size_t)m*n+j*bs;
    const Element* w_row=comp+(size_t)batch*ce+x*bs;
    uint64_t acc{0}; uint32_t pending{0};
    for(uint32_t y=0;y<bs;++y){
        acc+=(uint64_t)w_row[y]*b_row[y];
        if(++pending==REDUCE_INTERVAL){ acc=Reduce64(acc); pending=0; }
    }
    rhs[gid]=Reduce64(acc);
}
__global__ void FactoredWords(const Element* __restrict__ A,const Element* __restrict__ rhs,
                              uint32_t n,uint32_t bs,uint32_t bpa,uint32_t pcpr,uint32_t wpr,uint32_t me,uint32_t re,
                              uint32_t total_tiles,Element* __restrict__ out){
    // 2x2 word tile per warp (mirrors the patched ComputeFactoredWordsKernel)
    const uint32_t lane=threadIdx.x&31U;
    const uint32_t tile=blockIdx.x*(blockDim.x>>5U)+(threadIdx.x>>5U);
    if(tile>=total_tiles) return;
    const uint32_t tpa=bpa>>1U; const uint32_t tpr=tpa*tpa;
    const uint32_t batch=tile/tpr; const uint32_t lt=tile%tpr;
    const uint32_t j0=(lt%tpa)*2U; const uint32_t i0=(lt/tpa)*2U;
    const Element* ma=A+(size_t)batch*me; const Element* d=rhs+(size_t)batch*re;
    uint64_t a00{0},a01{0},a10{0},a11{0}; uint32_t pending{0};
    for(uint32_t x=0;x<bs;++x){
        const Element* ar0=ma+(size_t)(i0*bs+x)*n; const Element* ar1=ar0+(size_t)bs*n;
        const Element* dr0=d+(size_t)(j0*bs+x)*n;  const Element* dr1=dr0+(size_t)bs*n;
        for(uint32_t m=lane;m<n;m+=32U){
            const uint64_t a0=ar0[m],a1=ar1[m],d0=dr0[m],d1=dr1[m];
            a00+=a0*d0; a01+=a0*d1; a10+=a1*d0; a11+=a1*d1;
            if(++pending==REDUCE_INTERVAL){ a00=Reduce64(a00); a01=Reduce64(a01); a10=Reduce64(a10); a11=Reduce64(a11); pending=0; }
        }
    }
    Element v00=Reduce64(a00),v01=Reduce64(a01),v10=Reduce64(a10),v11=Reduce64(a11);
    for(uint32_t offset=16U;offset>0U;offset>>=1U){
        v00=FieldAdd(v00,__shfl_down_sync(0xffffffffU,v00,offset));
        v01=FieldAdd(v01,__shfl_down_sync(0xffffffffU,v01,offset));
        v10=FieldAdd(v10,__shfl_down_sync(0xffffffffU,v10,offset));
        v11=FieldAdd(v11,__shfl_down_sync(0xffffffffU,v11,offset));
    }
    if(lane==0){
        const uint32_t base=batch*wpr;
        out[base+i0*bpa+j0]=v00; out[base+i0*bpa+j0+1U]=v01;
        out[base+(i0+1U)*bpa+j0]=v10; out[base+(i0+1U)*bpa+j0+1U]=v11;
    }
}

static uint64_t rng_state=0x243f6a8885a308d3ULL;
static uint32_t NextRand(){ rng_state^=rng_state<<13; rng_state^=rng_state>>7; rng_state^=rng_state<<17; return (uint32_t)(rng_state>>32); }

int main(){
    // ================= Part 1: matrix-gen SHA =================
    const uint32_t N=512, ME=N*N, SEEDS=8;
    const size_t TOTAL=(size_t)SEEDS*ME;
    DeviceSeedBytes hseeds[SEEDS];
    for(uint32_t s=0;s<SEEDS;++s) for(int i=0;i<32;++i) hseeds[s].data[i]=(uint8_t)NextRand();
    DeviceSeedBytes* dseeds; CK(cudaMalloc(&dseeds,sizeof(hseeds))); CK(cudaMemcpy(dseeds,hseeds,sizeof(hseeds),cudaMemcpyHostToDevice));
    Element *d_go,*d_gw; CK(cudaMalloc(&d_go,TOTAL*4)); CK(cudaMalloc(&d_gw,TOTAL*4));
    const uint32_t gblocks=(uint32_t)((TOTAL+WORKSPACE_THREADS-1)/WORKSPACE_THREADS);
    GenKernel<false><<<gblocks,WORKSPACE_THREADS>>>(dseeds,TOTAL,ME,d_go);
    GenKernel<true ><<<gblocks,WORKSPACE_THREADS>>>(dseeds,TOTAL,ME,d_gw);
    CK(cudaDeviceSynchronize());
    Element* ho=(Element*)malloc(TOTAL*4); Element* hw=(Element*)malloc(TOTAL*4);
    CK(cudaMemcpy(ho,d_go,TOTAL*4,cudaMemcpyDeviceToHost)); CK(cudaMemcpy(hw,d_gw,TOTAL*4,cudaMemcpyDeviceToHost));
    size_t mism=0; for(size_t i=0;i<TOTAL;++i) if(ho[i]!=hw[i]) ++mism;
    printf("matrixgen byte-exact: seeds=%u elements=%zu mismatches=%zu -> %s\n",SEEDS,TOTAL,mism,mism==0?"PASS":"FAIL");
    if(mism) return 1;
    // edge paths: retry + fallback variants
    const uint32_t EN=65536;
    uint32_t *d_eo,*d_ew; CK(cudaMalloc(&d_eo,(size_t)EN*4)); CK(cudaMalloc(&d_ew,(size_t)EN*4));
    EdgeKernel<false><<<(EN+255)/256,256>>>(dseeds,SEEDS,EN/SEEDS,d_eo);
    EdgeKernel<true ><<<(EN+255)/256,256>>>(dseeds,SEEDS,EN/SEEDS,d_ew);
    CK(cudaDeviceSynchronize());
    uint32_t* heo=(uint32_t*)malloc((size_t)EN*4); uint32_t* hew=(uint32_t*)malloc((size_t)EN*4);
    CK(cudaMemcpy(heo,d_eo,(size_t)EN*4,cudaMemcpyDeviceToHost)); CK(cudaMemcpy(hew,d_ew,(size_t)EN*4,cudaMemcpyDeviceToHost));
    mism=0; for(size_t i=0;i<EN;++i) if(heo[i]!=hew[i]) ++mism;
    printf("retry/fallback byte-exact: cases=%u mismatches=%zu -> %s\n",EN,mism,mism==0?"PASS":"FAIL");
    if(mism) return 1;
    // matrixgen-seed-midstate (2-kernel) vs ORIGINAL (the consensus reference)
    Element* d_gm; CK(cudaMalloc(&d_gm,TOTAL*4));
    uint32_t* d_mid; CK(cudaMalloc(&d_mid,(size_t)SEEDS*16*4));
    PrecomputeMidstatesK<<<(SEEDS+255)/256,256>>>(dseeds,SEEDS,d_mid);
    GenKernelMid2<<<gblocks,WORKSPACE_THREADS>>>(dseeds,d_mid,TOTAL,ME,d_gm);
    CK(cudaDeviceSynchronize());
    Element* hm=(Element*)malloc(TOTAL*4); CK(cudaMemcpy(hm,d_gm,TOTAL*4,cudaMemcpyDeviceToHost));
    mism=0; for(size_t i=0;i<TOTAL;++i) if(ho[i]!=hm[i]) ++mism;
    printf("matrixgen midstate byte-exact: elements=%zu mismatches=%zu -> %s\n",TOTAL,mism,mism==0?"PASS":"FAIL");
    if(mism) return 1;

    // ================= Part 2: fused kernel =================
    const uint32_t BS=16, BPA=N/BS, PCPR=BPA*BPA, WPR=PCPR, CE=BS*BS, BATCH=4;
    const size_t MT=(size_t)BATCH*ME, WT=(size_t)BATCH*WPR, CT=(size_t)BATCH*CE;
    Element* hA=(Element*)malloc(MT*4); Element* hB=(Element*)malloc(MT*4); Element* hC=(Element*)malloc(CT*4);
    for(size_t i=0;i<MT;++i){ hA[i]=NextRand()%MODULUS; hB[i]=NextRand()%MODULUS; }
    for(size_t i=0;i<CT;++i) hC[i]=NextRand()%MODULUS;
    Element *dA,*dB,*dC,*d_fo,*d_fn;
    CK(cudaMalloc(&dA,MT*4)); CK(cudaMalloc(&dB,MT*4)); CK(cudaMalloc(&dC,CT*4));
    CK(cudaMalloc(&d_fo,WT*4)); CK(cudaMalloc(&d_fn,WT*4));
    CK(cudaMemcpy(dA,hA,MT*4,cudaMemcpyHostToDevice)); CK(cudaMemcpy(dB,hB,MT*4,cudaMemcpyHostToDevice)); CK(cudaMemcpy(dC,hC,CT*4,cudaMemcpyHostToDevice));
    const uint32_t fgrid=BATCH*PCPR;
    FusedOrig<<<fgrid,MAX_BLOCK_THREADS>>>(dA,dB,dC,N,BS,BPA,PCPR,WPR,ME,CE,d_fo);
    FusedNew <<<fgrid,MAX_BLOCK_THREADS>>>(dA,dB,dC,N,BS,BPA,PCPR,WPR,ME,CE,d_fn);
    CK(cudaDeviceSynchronize());
    Element* hfo=(Element*)malloc(WT*4); Element* hfn=(Element*)malloc(WT*4);
    CK(cudaMemcpy(hfo,d_fo,WT*4,cudaMemcpyDeviceToHost)); CK(cudaMemcpy(hfn,d_fn,WT*4,cudaMemcpyDeviceToHost));
    mism=0; for(size_t i=0;i<WT;++i) if(hfo[i]!=hfn[i]) ++mism;
    printf("fused orig-vs-new byte-exact: words=%zu mismatches=%zu -> %s\n",WT,mism,mism==0?"PASS":"FAIL");
    if(mism) return 1;
    // CPU reference (third witness) on batch entry 0, first 64 pairs
    size_t cpu_mism=0;
    for(uint32_t lp=0;lp<64;++lp){
        const uint32_t j=lp%BPA, i=lp/BPA;
        Element word=0;
        for(uint32_t x=0;x<BS;++x) for(uint32_t y=0;y<BS;++y){
            const uint32_t row=i*BS+x, col=j*BS+y;
            uint64_t acc=0; uint32_t pending=0;
            for(uint32_t m=0;m<N;++m){
                acc+=(uint64_t)hA[(size_t)row*N+m]*hB[(size_t)m*N+col];
                if(++pending==REDUCE_INTERVAL){ acc=Reduce64(acc); pending=0; }
            }
            word=FieldAdd(word,FieldMul(Reduce64(acc),hC[x*BS+y]));
        }
        if(word!=hfn[lp]) ++cpu_mism;
    }
    printf("fused vs CPU reference: pairs=64 mismatches=%zu -> %s\n",cpu_mism,cpu_mism==0?"PASS":"FAIL");
    if(cpu_mism) return 1;

    // ================= Part 3: factored compression =================
    const uint32_t RE=BS*N*BPA;                      // D words per request
    const size_t RT=(size_t)BATCH*RE;
    Element *d_rhs,*d_ff; CK(cudaMalloc(&d_rhs,RT*4)); CK(cudaMalloc(&d_ff,WT*4));
    const uint32_t rhs_blocks=(uint32_t)((RT+255)/256);
    const uint32_t TILES=BATCH*((BPA/2)*(BPA/2));
    const uint32_t warps_per_block=256/32, word_blocks=(TILES+warps_per_block-1)/warps_per_block;
    FactoredRhs<<<rhs_blocks,256>>>(dB,dC,N,BS,RT,RE,ME,CE,d_rhs);
    FactoredWords<<<word_blocks,256>>>(dA,d_rhs,N,BS,BPA,PCPR,WPR,ME,RE,TILES,d_ff);
    CK(cudaDeviceSynchronize());
    Element* hff=(Element*)malloc(WT*4);
    CK(cudaMemcpy(hff,d_ff,WT*4,cudaMemcpyDeviceToHost));
    mism=0; for(size_t i=0;i<WT;++i) if(hfo[i]!=hff[i]) ++mism;
    printf("factored vs fused-orig byte-exact: words=%zu mismatches=%zu -> %s\n",WT,mism,mism==0?"PASS":"FAIL");
    if(mism) return 1;

    // ================= throughput (contended w/ live miner; ratio is the signal) =================
    // Skipped when BTX_VAL_NO_PERF is set: benchmarking under a sanitizer (e.g. racecheck) isn't
    // representative (instrumentation inflates and distorts timing), and this timing loop's ~120
    // shared-mem kernel re-launches overrun racecheck's access-record tracker. The parity section
    // above already exercises every kernel once, including both shared-memory reductions
    // (FusedOrig/FusedNew), so racecheck stays complete.
    if(!getenv("BTX_VAL_NO_PERF")){
    cudaEvent_t s,e; CK(cudaEventCreate(&s)); CK(cudaEventCreate(&e)); float ms;
    printf("\nkernel              orig(ms)    new(ms)   speedup\n");
    for(int r=0;r<3;++r){
        const int GI=20;
        CK(cudaEventRecord(s)); for(int i=0;i<GI;++i) GenKernel<false><<<gblocks,WORKSPACE_THREADS>>>(dseeds,TOTAL,ME,d_go); CK(cudaEventRecord(e)); CK(cudaEventSynchronize(e));
        CK(cudaEventElapsedTime(&ms,s,e)); const double go=ms/GI;
        CK(cudaEventRecord(s)); for(int i=0;i<GI;++i) GenKernel<true ><<<gblocks,WORKSPACE_THREADS>>>(dseeds,TOTAL,ME,d_gw); CK(cudaEventRecord(e)); CK(cudaEventSynchronize(e));
        CK(cudaEventElapsedTime(&ms,s,e)); const double gw=ms/GI;
        printf("matrixgen[%d]    %10.3f %10.3f  %+7.1f%%\n",r,go,gw,(go/gw-1.0)*100.0);
    }
    for(int r=0;r<3;++r){
        const int FI=20;
        CK(cudaEventRecord(s)); for(int i=0;i<FI;++i) FusedOrig<<<fgrid,MAX_BLOCK_THREADS>>>(dA,dB,dC,N,BS,BPA,PCPR,WPR,ME,CE,d_fo); CK(cudaEventRecord(e)); CK(cudaEventSynchronize(e));
        CK(cudaEventElapsedTime(&ms,s,e)); const double fo=ms/FI;
        CK(cudaEventRecord(s)); for(int i=0;i<FI;++i) FusedNew<<<fgrid,MAX_BLOCK_THREADS>>>(dA,dB,dC,N,BS,BPA,PCPR,WPR,ME,CE,d_fn); CK(cudaEventRecord(e)); CK(cudaEventSynchronize(e));
        CK(cudaEventElapsedTime(&ms,s,e)); const double fn=ms/FI;
        printf("fused[%d]        %10.3f %10.3f  %+7.1f%%\n",r,fo,fn,(fo/fn-1.0)*100.0);
    }
    for(int r=0;r<3;++r){
        const int FI=20;
        CK(cudaEventRecord(s)); for(int i=0;i<FI;++i) FusedNew<<<fgrid,MAX_BLOCK_THREADS>>>(dA,dB,dC,N,BS,BPA,PCPR,WPR,ME,CE,d_fn); CK(cudaEventRecord(e)); CK(cudaEventSynchronize(e));
        CK(cudaEventElapsedTime(&ms,s,e)); const double fn=ms/FI;
        CK(cudaEventRecord(s)); for(int i=0;i<FI;++i){ FactoredRhs<<<rhs_blocks,256>>>(dB,dC,N,BS,RT,RE,ME,CE,d_rhs); FactoredWords<<<word_blocks,256>>>(dA,d_rhs,N,BS,BPA,PCPR,WPR,ME,RE,TILES,d_ff); } CK(cudaEventRecord(e)); CK(cudaEventSynchronize(e));
        CK(cudaEventElapsedTime(&ms,s,e)); const double ff=ms/FI;
        printf("factored[%d]     %10.3f %10.3f  %+7.1f%%   (col1=fused-new, col2=factored K1+K2)\n",r,fn,ff,(fn/ff-1.0)*100.0);
    }
    } // end BTX_VAL_NO_PERF gate
    printf("\nALL PASS\n");
    return 0;
}
