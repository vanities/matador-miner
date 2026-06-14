// sims/no_premine_proof.cpp
//
// Deterministic, CPU-only proof of the BTX v3 "no premining the next block"
// property, built directly on the MATADOR miner's own CPU PoW reference
// (src/pow/matmul_pow.cpp). NO GPU, NO CUDA, NO live-miner involvement.
//
// CLAIM UNDER TEST
// ----------------
// BTX v3 (active at block height >= kMatMulSeedV3Height = 130500) derives the
// per-nonce MatMul seeds (and therefore the 512x512 matrices A,B and the whole
// proof-of-work digest) from the PARENT context: the parent block hash
// (prev_hash) AND the parent median-time-past (parent_mtp), together with the
// mutable header fields. Concretely, the reference does:
//
//     seed = DeterministicMatMulSeedV3(prev_hash, parent_mtp, height, version,
//                                      merkle, time, bits, nonce, dim, which)
//
// and VerifySolution() routes to that V3 derivation whenever
// block_height >= 130500. Because prev_hash and parent_mtp are folded into the
// seed's SHA-256 preimage, the work for block N is a pure function of block
// N-1. You cannot compute block N's work before its parent exists, and work
// computed against one parent is wrong for any other parent.
//
// We demonstrate this at the algorithm level with two experiments:
//
//   A. Same nonce, two DIFFERENT parents (P and P'), everything else identical.
//      Show seed(P) != seed(P') and digest(P,nonce) != digest(P',nonce).
//      => a precomputed seed/matrix/digest for P is simply the wrong value
//         for P'.
//
//   B. Find a real solution: scan nonces under P against a LOOSE target until
//      VerifySolution() passes for P. Then feed that exact winning nonce to
//      VerifySolution() under P' and show it FAILS.
//      => a *solved* block for parent P does not validate against parent P';
//         premined work cannot be carried forward to the next block.
//
// We build MatMulJob by hand (the same way tests/test_pow.cpp does in
// test_pow_smoke) so the harness depends only on src/pow/*.cpp and never pulls
// in the stratum layer. The V3 seed derivation and VerifySolution are called
// directly from the reference; nothing about the seed message is reconstructed
// by hand.

#include "pow/matmul_pow.h"
#include "pow/uint256_stub.h"

#include <cstdint>
#include <cstdio>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

using btx::pow::MatMulJob;
using btx::pow::DeterministicMatMulSeedV3;
using btx::pow::VerifySolution;
using btx::pow::DigestMeetsTarget;
using btx::pow::kMatMulSeedV3Height;

// Big-endian (Bitcoin display) hex of a uint256, matching uint256::GetHex().
static std::string Hex(const uint256& v) { return v.GetHex(); }

static std::string HexBytesBE(const std::vector<uint8_t>& b) {
    // Print MSB-first (index 31 down to 0), to read like a target/digest.
    std::ostringstream ss;
    ss << std::hex << std::setfill('0');
    for (int i = static_cast<int>(b.size()) - 1; i >= 0; --i)
        ss << std::setw(2) << static_cast<unsigned>(b[i]);
    return ss.str();
}

// Build a v3 MatMulJob for a given parent context. seed_a/seed_b are left null:
// VerifySolution recomputes them via DeterministicMatMulSeedV3 because
// block_height >= kMatMulSeedV3Height and has_parent_mtp is set.
static MatMulJob MakeV3Job(const uint256& prev_hash,
                           int64_t parent_mtp,
                           const uint256& merkle,
                           int32_t version,
                           uint32_t time,
                           uint32_t bits,
                           uint32_t height,
                           const std::vector<uint8_t>& target) {
    MatMulJob job;
    job.n = 512;            // 512x512 matrices, per spec.
    job.b = 16;             // block size.
    job.r = 8;              // noise rank.
    job.version = version;
    job.prev_hash = prev_hash;
    job.merkle_root = merkle;
    job.time = time;
    job.bits = bits;
    job.block_height = height;
    job.parent_mtp = parent_mtp;
    job.has_parent_mtp = true;       // required for the v3 path.
    job.epsilon_bits = 0;            // disable the pre-hash sigma gate so the
                                     // digest-vs-target comparison is the only
                                     // acceptance test (keeps the proof clean).
    job.target = target;             // digest must be <= this.
    return job;
}

int main() {
    std::cout << "=== BTX v3 no-premine proof (CPU-only, MATADOR pow reference) ===\n\n";
    std::cout << "kMatMulSeedV3Height = " << kMatMulSeedV3Height
              << "  (v3 active at this height and above)\n\n";

    // ---- Common, parent-independent header fields (held identical) ----
    const int32_t  kVersion = 536870912;     // 0x20000000
    const uint32_t kTime    = 1781098511U;
    const uint32_t kBits    = 0x1d14bd00U;
    const uint32_t kHeight  = 130500U;        // exactly at v3 activation.
    const uint16_t kDim     = 512;

    uint256 merkle;
    uint256_from_hex(merkle,
        "fe14530b149adfa21a45f7d2666f3c2dbef7296333398ba208ab77ea6b44a6e2");

    // ---- Parent P ----
    uint256 H_P;
    uint256_from_hex(H_P,
        "e41768fe0c8ed2d40b967c981e3af7cddf6fc495f844563836756fa76a0d2ec9");
    const int64_t M_P = 1780000000LL;   // parent median-time-past for P.

    // ---- Parent P' (DIFFERENT parent: flip prev_hash and parent_mtp) ----
    uint256 H_Pp;
    uint256_from_hex(H_Pp,
        "00000000000000000000000000000000000000000000000000000000deadbeef");
    const int64_t M_Pp = 1780000123LL;  // different parent MTP.

    std::cout << "Parent P  : prev_hash=" << Hex(H_P)  << "  parent_mtp=" << M_P  << "\n";
    std::cout << "Parent P' : prev_hash=" << Hex(H_Pp) << "  parent_mtp=" << M_Pp << "\n";
    std::cout << "Shared    : version=" << kVersion << " time=" << kTime
              << " bits=0x" << std::hex << kBits << std::dec
              << " height=" << kHeight << " merkle=" << Hex(merkle) << "\n\n";

    int failures = 0;

    // ================================================================
    // EXPERIMENT A: same nonce, two parents -> seeds and digest differ.
    // ================================================================
    const uint64_t kFixedNonce = 26336739459072ULL;
    std::cout << "---- Experiment A: same nonce (" << kFixedNonce
              << "), different parent => different work ----\n";

    // Seeds are derived straight from the reference's v3 function.
    const uint256 seedA_P  = DeterministicMatMulSeedV3(
        H_P,  M_P,  static_cast<int32_t>(kHeight), kVersion, merkle, kTime, kBits,
        kFixedNonce, kDim, 0);
    const uint256 seedB_P  = DeterministicMatMulSeedV3(
        H_P,  M_P,  static_cast<int32_t>(kHeight), kVersion, merkle, kTime, kBits,
        kFixedNonce, kDim, 1);
    const uint256 seedA_Pp = DeterministicMatMulSeedV3(
        H_Pp, M_Pp, static_cast<int32_t>(kHeight), kVersion, merkle, kTime, kBits,
        kFixedNonce, kDim, 0);
    const uint256 seedB_Pp = DeterministicMatMulSeedV3(
        H_Pp, M_Pp, static_cast<int32_t>(kHeight), kVersion, merkle, kTime, kBits,
        kFixedNonce, kDim, 1);

    std::cout << "seed_a(P)  = " << Hex(seedA_P)  << "\n";
    std::cout << "seed_a(P') = " << Hex(seedA_Pp) << "\n";
    std::cout << "seed_b(P)  = " << Hex(seedB_P)  << "\n";
    std::cout << "seed_b(P') = " << Hex(seedB_Pp) << "\n";

    // For the digest, use a wide-open target so VerifySolution returns the
    // digest via out_digest regardless of whether it "passes" (all-0xff means
    // every digest is <= target). We only compare the two digests here.
    std::vector<uint8_t> open_target(32, 0xff);
    MatMulJob jobP_open  = MakeV3Job(H_P,  M_P,  merkle, kVersion, kTime, kBits, kHeight, open_target);
    MatMulJob jobPp_open = MakeV3Job(H_Pp, M_Pp, merkle, kVersion, kTime, kBits, kHeight, open_target);

    uint256 digP, digPp;
    const bool okP  = VerifySolution(jobP_open,  kFixedNonce, kTime, digP);
    const bool okPp = VerifySolution(jobPp_open, kFixedNonce, kTime, digPp);
    std::cout << "digest(P,  nonce) = " << Hex(digP)  << "  (verify_vs_open_target=" << okP  << ")\n";
    std::cout << "digest(P', nonce) = " << Hex(digPp) << "  (verify_vs_open_target=" << okPp << ")\n";

    const bool seeds_differ  = (seedA_P != seedA_Pp) && (seedB_P != seedB_Pp);
    const bool digest_differ = (digP != digPp);
    std::cout << "ASSERT seed(P) != seed(P')   : " << (seeds_differ  ? "PASS" : "FAIL") << "\n";
    std::cout << "ASSERT digest(P) != digest(P'): " << (digest_differ ? "PASS" : "FAIL") << "\n\n";
    if (!seeds_differ)  ++failures;
    if (!digest_differ) ++failures;

    // ================================================================
    // EXPERIMENT B: solve under P at a loose target, then verify the
    // winning nonce under P' (must fail).
    // ================================================================
    std::cout << "---- Experiment B: solve under P, replay winning nonce under P' ----\n";

    // Loose target: require the digest's two most-significant bytes to be zero,
    // i.e. digest <= 0x0000ffff...ff. In the reference's comparison index 31 is
    // the most-significant byte, so we set [31]=[30]=0x00 (must be matched) and
    // leave the rest 0xff (always satisfied once the top two bytes are zero).
    // That is roughly a 1-in-65536 hit rate, so a CPU solve lands in ~65k tries
    // on average while still being a genuinely selective target (most random
    // digests fail it, so a precomputed-for-the-wrong-parent digest will fail).
    std::vector<uint8_t> loose_target(32, 0xff);
    loose_target[31] = 0x00;   // most-significant byte must be 0x00.
    loose_target[30] = 0x00;   // second most-significant byte must be 0x00.
    std::cout << "loose target (MSB-first) = " << HexBytesBE(loose_target)
              << "  (digest passes iff its top two bytes are 00)\n";

    MatMulJob jobP_loose  = MakeV3Job(H_P,  M_P,  merkle, kVersion, kTime, kBits, kHeight, loose_target);
    MatMulJob jobPp_loose = MakeV3Job(H_Pp, M_Pp, merkle, kVersion, kTime, kBits, kHeight, loose_target);

    // The CPU reference does a full 512x512 blocked matmul + low-rank noise per
    // nonce (~200ms/try single-threaded), so the scan is parallelized across
    // cores with OpenMP. The reference seed/digest functions are pure (no shared
    // mutable state), so this is safe. We scan in successive blocks and, within
    // each block, take the SMALLEST winning nonce so the result is deterministic
    // and reproducible regardless of thread scheduling.
    const uint64_t kStart      = 0;
    const uint64_t kMaxTries   = 50ULL * 1000ULL * 1000ULL;  // 50M ceiling.
    const uint64_t kBlock      = 16384;  // nonces per parallel block.
    bool solved = false;
    uint64_t win_nonce = 0;
    uint256 win_digest;

    for (uint64_t base = kStart; base < kStart + kMaxTries && !solved; base += kBlock) {
        uint64_t local_best = UINT64_MAX;  // smallest winning nonce in this block.
        #pragma omp parallel for schedule(static)
        for (long long off = 0; off < (long long)kBlock; ++off) {
            // Skip work once a smaller hit is already known in this block.
            if ((uint64_t)off >= (local_best - base)) continue;
            const uint64_t nonce = base + (uint64_t)off;
            uint256 d;
            if (VerifySolution(jobP_loose, nonce, kTime, d)) {
                #pragma omp critical
                {
                    if (nonce < local_best) local_best = nonce;
                }
            }
        }
        if (local_best != UINT64_MAX) {
            solved = true;
            win_nonce = local_best;
            VerifySolution(jobP_loose, win_nonce, kTime, win_digest);
            std::cout << "[solve] HIT under P at nonce=" << win_nonce
                      << " (scanned <= " << (base + kBlock - kStart) << " nonces)\n";
            break;
        }
        std::cout << "[solve] ... " << (base + kBlock - kStart)
                  << " nonces scanned under P (no hit yet)\n";
    }

    if (!solved) {
        std::cout << "ASSERT solved-under-P : FAIL (no hit within " << kMaxTries
                  << " tries; loosen target and rerun)\n";
        ++failures;
    } else {
        // Confirm the win really validates under P (digest <= target).
        uint256 reP;
        const bool reP_ok = VerifySolution(jobP_loose, win_nonce, kTime, reP);
        std::cout << "VerifySolution(P,  nonce=" << win_nonce << ") = "
                  << (reP_ok ? "TRUE " : "FALSE")
                  << "  digest=" << Hex(reP) << "\n";

        // Now replay that exact winning nonce under parent P'.
        uint256 dPp;
        const bool pp_ok = VerifySolution(jobPp_loose, win_nonce, kTime, dPp);
        std::cout << "VerifySolution(P', nonce=" << win_nonce << ") = "
                  << (pp_ok ? "TRUE " : "FALSE")
                  << "  digest=" << Hex(dPp) << "\n";

        // Also show the digest under P' exceeds the loose target (i.e. why it fails).
        const bool pp_meets = DigestMeetsTarget(dPp, loose_target);
        std::cout << "digest(P') <= loose_target ? " << (pp_meets ? "yes" : "NO (exceeds target)")
                  << "\n";

        const bool b_holds = reP_ok && !pp_ok;
        std::cout << "ASSERT solved-under-P is INVALID-under-P' : "
                  << (b_holds ? "PASS" : "FAIL") << "\n";
        if (!b_holds) ++failures;
    }

    // ================================================================
    // CONCLUSION
    // ================================================================
    std::cout << "\n=== RESULT ===\n";
    if (failures == 0) {
        std::cout << "ALL ASSERTS PASSED.\n";
        std::cout << "CONCLUSION: Under BTX v3 the per-nonce MatMul seeds (and thus the\n"
                     "512x512 matrices A,B and the final proof-of-work digest) are a\n"
                     "deterministic function of the PARENT context (parent block hash +\n"
                     "parent median-time-past). Work computed for parent P does not match\n"
                     "parent P', and a block solved against P is invalid against P'.\n"
                     "Therefore the next block cannot be premined: its proof-of-work cannot\n"
                     "exist until its actual parent does, and work cannot be carried over\n"
                     "from a different parent.\n";
        return 0;
    }
    std::cout << failures << " ASSERT(S) FAILED.\n";
    std::cout << "CONCLUSION: the v3 parent-binding property did NOT hold as expected in\n"
                 "this run; investigate before trusting the no-premine claim.\n";
    return 1;
}
