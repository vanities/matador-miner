# BTX v3 "no premining the next block" proof (CPU-only)

This document records a deterministic, CPU-only proof that BTX v3 ties each
block's proof-of-work to its PARENT, so the next block cannot be premined. The
proof is built directly on the MATADOR miner's own CPU PoW reference
(`src/pow/matmul_pow.cpp`). No GPU and no live-miner container were involved:
the build and run are pure CPU, on host `pc`, while a separate GPU batch sweep
kept ownership of the GPU the whole time.

## What v3 does (the property under test)

BTX v3 is active at block height >= `kMatMulSeedV3Height` (130500). At that
height and above, the miner derives the per-nonce MatMul seeds via
`DeterministicMatMulSeedV3(...)`, whose SHA-256 preimage folds in the PARENT
context:

- `prev_hash` (the parent block hash), and
- `parent_mtp` (the parent median-time-past),

together with the mutable header fields (version, merkle root, time, bits,
nonce, matmul dim). Those seeds produce the 512x512 matrices A and B, and hence
the final proof-of-work digest. `VerifySolution(...)` automatically routes to
this v3 derivation whenever `block_height >= 130500`.

Because `prev_hash` and `parent_mtp` are inputs to the seed hash, the work for
block N is a pure function of block N-1. You cannot compute block N's work
before its parent exists, and work computed against one parent is the wrong
value for any other parent.

## How the harness proves it

The harness (`sims/no_premine_proof.cpp`) builds two parent contexts that are
identical in every header field EXCEPT the parent binding:

- Parent P : `prev_hash = e41768fe...0d2ec9`, `parent_mtp = 1780000000`
- Parent P': `prev_hash = 00000000...deadbeef`, `parent_mtp = 1780000123`

It then runs two experiments:

- Experiment A: for one fixed nonce, derive the v3 seeds and the digest under
  both P and P'. Assert the seeds differ and the digests differ. This shows a
  precomputed seed/matrix/digest for P is simply the wrong value for P'.
- Experiment B (stronger): pick a loose target (digest must have its two
  most-significant bytes equal to zero, roughly a 1-in-65536 hit), scan nonces
  under P until `VerifySolution` passes for P, then replay that exact winning
  nonce under P' and show `VerifySolution` returns FALSE (digest exceeds the
  target). This shows a *solved* block for parent P is invalid for parent P', so
  premined work cannot be carried to the next block.

The v3 seed function and `VerifySolution` are called directly from the
reference. Nothing about the seed message is reconstructed by hand. The
`MatMulJob` is built directly (the same way `tests/test_pow.cpp` does in
`test_pow_smoke`), so the harness depends only on `src/pow/*.cpp` and never
pulls in the stratum layer.

## Build and run command (CPU-only, no CUDA)

The scan is parallelized with OpenMP because the CPU reference does a full
512x512 blocked matmul plus low-rank noise per nonce (about 219 ms per try
single-threaded, measured on `pc`). The reference seed/digest functions are
pure (no shared mutable state), so the parallel scan is safe; it takes the
smallest winning nonce per block, so the result is deterministic.

```bash
ssh pc 'cd ~/nvminer-dev && \
  g++ -O2 -std=c++17 -fopenmp -Isrc \
      sims/no_premine_proof.cpp src/pow/*.cpp \
      -o /tmp/no_premine_proof && \
  OMP_NUM_THREADS=14 /tmp/no_premine_proof'
```

Source compiled: `~/nvminer-dev/sims/no_premine_proof.cpp` against
`~/nvminer-dev/src/pow/*.cpp`. The clone on `pc` was at commit `9a7e50e`
(v0.2.33 of the patched fork). No CUDA headers are pulled in by `src/pow/`, so
the build is pure CPU.

## Exact program output

```
=== BTX v3 no-premine proof (CPU-only, MATADOR pow reference) ===

kMatMulSeedV3Height = 130500  (v3 active at this height and above)

Parent P  : prev_hash=e41768fe0c8ed2d40b967c981e3af7cddf6fc495f844563836756fa76a0d2ec9  parent_mtp=1780000000
Parent P' : prev_hash=00000000000000000000000000000000000000000000000000000000deadbeef  parent_mtp=1780000123
Shared    : version=536870912 time=1781098511 bits=0x1d14bd00 height=130500 merkle=fe14530b149adfa21a45f7d2666f3c2dbef7296333398ba208ab77ea6b44a6e2

---- Experiment A: same nonce (26336739459072), different parent => different work ----
seed_a(P)  = 5271bb8a5f7f505573ca2ce2e0e3bfb8b0f88731a5b9279abf9a26e5cb477c69
seed_a(P') = b7dd0fd275e64461a0fff82628a1da831022231ee2ee18a9372c0bb2ecb89107
seed_b(P)  = e8bb161f25ea3bcf9421e4be687999c75c04384321d03bd49c32a7f66e76a7f8
seed_b(P') = 639f2d5011253a9bcfe25833ccdb5642711bd969e60dec57bf2fa8e083085f01
digest(P,  nonce) = 36ce5b4fe55600c4537316ddcebacb2facada86676a90174844a4a08c1646bfb  (verify_vs_open_target=1)
digest(P', nonce) = 218925ed2daf9cf10f8d907a13d586a9e67ee54ede8df1aae1a2c62f74bc8b90  (verify_vs_open_target=1)
ASSERT seed(P) != seed(P')   : PASS
ASSERT digest(P) != digest(P'): PASS

---- Experiment B: solve under P, replay winning nonce under P' ----
loose target (MSB-first) = 0000ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff  (digest passes iff its top two bytes are 00)
[solve] HIT under P at nonce=11639 (scanned <= 16384 nonces)
VerifySolution(P,  nonce=11639) = TRUE   digest=00008657fe0b6d366554205f0efcc8046582b1f02de7e94833b2e3536b4623df
VerifySolution(P', nonce=11639) = FALSE  digest=a1d45274b6db14ee93daeb8459b721663ce1d28ed79fbfd7c7668c1bf78ad00e
digest(P') <= loose_target ? NO (exceeds target)
ASSERT solved-under-P is INVALID-under-P' : PASS

=== RESULT ===
ALL ASSERTS PASSED.
CONCLUSION: Under BTX v3 the per-nonce MatMul seeds (and thus the
512x512 matrices A,B and the final proof-of-work digest) are a
deterministic function of the PARENT context (parent block hash +
parent median-time-past). Work computed for parent P does not match
parent P', and a block solved against P is invalid against P'.
Therefore the next block cannot be premined: its proof-of-work cannot
exist until its actual parent does, and work cannot be carried over
from a different parent.
```

## Reading of the result

- Experiment A: the same nonce produces completely different seeds and a
  completely different digest under P versus P'. Flipping only the parent hash
  and the parent MTP, with every other header field held identical, changes the
  entire proof-of-work. A matrix, seed, or digest you precomputed for parent P
  is the wrong value for parent P'.
- Experiment B: a nonce that genuinely solves the block under parent P
  (`VerifySolution(P, 11639) = TRUE`, digest `00008657...` is below the loose
  target) does NOT solve the block under parent P'
  (`VerifySolution(P', 11639) = FALSE`, digest `a1d45274...` is above the
  target). A solved block for one parent is invalid for a different parent.

## Plain-English conclusion

BTX v3 binds every block's proof-of-work to its parent. The matrices and the
digest for block N depend on the parent's block hash and the parent's
median-time-past, so the work for block N cannot even be computed until block
N-1 actually exists. And work you did against one parent is useless for any
other parent: the seeds change, the matrices change, the digest changes, and a
solution that was valid for one parent fails verification for another. There is
therefore no way to premine the next block ahead of time, and no way to carry
mining work from a competing or stale parent onto the real chain tip.

## Caveats and honesty notes

- The v3 API was directly callable. `DeterministicMatMulSeedV3` and
  `VerifySolution` are public in `matmul_pow.h` and route to the v3 path
  automatically for `block_height >= 130500` with `has_parent_mtp` set. The seed
  preimage was NOT reconstructed by hand; the reference functions were called as
  the consensus path uses them.
- The clone present on `pc` was at commit `9a7e50e` (v0.2.33), not the
  `df4e50e` referenced in the task. The relevant reference files in `src/pow/`
  were present and self-contained, and the v3 derivation binds `prev_hash` and
  `parent_mtp` exactly as the spec implies (confirmed by reading
  `DeterministicMatMulSeedV3` in `matmul_pow.cpp`).
- The loose target in Experiment B (top two digest bytes must be zero) is about
  a 1-in-65536 hit. With a random digest, the probability that the wrong-parent
  replay would coincidentally also pass is about 1 in 65536, so the FALSE result
  under P' is the overwhelmingly expected outcome and not a fluke. The hit under
  P landed at nonce 11639 (within the first 16384 nonces), faster than the
  roughly 65k average.
- The per-nonce CPU cost is high (about 219 ms single-threaded) because the
  reference computes the full 512x512 blocked matmul plus low-rank noise on the
  CPU. That is why the scan was parallelized with OpenMP. This does not affect
  correctness; it only changes wall-clock time. The result (smallest winning
  nonce) is deterministic and reproducible.
- Everything behaved exactly as the v3 spec implies. No discrepancies were
  observed.
