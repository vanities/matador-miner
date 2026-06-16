# matador-miner CUDA autoresearch log

Bench-iterate loop: hypothesize -> implement -> `build.sh` (3s incremental) ->
`bench/kernel-bench.sh` (clean v3 nonce/s) -> `bench/validate.sh` (byte-exact) ->
KEEP if faster + correct, else REVERT. Every candidate logged here, wins and dead-ends.

**Measurement:** clean `btx-matmul-solve-bench`, v3 nonce-seeded path, fixed
(`--block-height 131000 --nonce-seed-height 130500 --parent-mtp 1781450513
--product-digest-height 130000 --backend cuda --gpu-inputs 1`). Headline metric =
`nonces_per_sec` median (total nonces scanned; ~10x the digest-attempt count because
the prehash epsilon prefilter rejects ~90% cheaply; it scales with digest speed).

## Baseline (2026-06-15, btx 0.32.11 + overlap patch, RTX 5090 sm_120)

| metric | value |
|---|---|
| nonces/sec (median, async=0) | **~153,500** |
| digest-attempts/sec | ~14,800 (matches live monolith) |

Established as the number to beat.

## Candidates

| # | hypothesis | result | nonces/sec | byte-exact | verdict |
|---|---|---|---|---|---|
| 1 | Freivalds-during-search: C' computed per-nonce -> defer to winner | researched pow.cpp: Freivalds only in validation path + post-solve population, NOT in the per-nonce search loop | n/a | n/a | **REJECTED** (already optimal, no build spent) |
| 2 | Cross-nonce matrix-gen sharing: generate the 512x512 matrix once per batch, reuse across nonces | v3 binds the matrix SEED to the per-nonce header+parent_mtp BY DESIGN (anti-ASIC) -> the matrix is intentionally nonce-dependent and cannot be cached/shared. The only block-constant part (header-prefix SHA midstate) is ALREADY shared via the seed/template-midstate patch | n/a | n/a | **REJECTED** (consensus-mandated per-nonce regen) |
| 3 | Grid/launch config sweep (batch-size override) | 512=148.5k, 1024=147.7k, 2048=148.2k vs default ~153.5k; 4096 STALLED the GPU | all <baseline | n/a | **REJECTED** (auto-resolved default is optimal; forcing batch-size is ~3% slower / large = stall) |
| -- | clean same-process overlap A/B (async=0 vs =1, default batch, gpu_inputs=1) | async=0 = **150,478 nonces/sec** (works); async=1 = **STALLS to 7% util** (no result) in solve-bench AND matador-miner standalone, but WORKS at 100% in btxd live (16.8k digest/s @571W) | n/a | **KEY FINDING** |

## KEY FINDING: the overlap (PR #72) is context-dependent

`async=1` (the CPU/GPU prepare-overlap, PR #72) **stalls to ~3-7% util in every standalone
caller** (solve-bench, matador-miner) but **runs at 100% util under btxd's mining loop**.
Same patched binary/tree - so it's a RUNTIME/calling-pattern issue, almost certainly a
timing-sensitive deadlock in the overlap loop's future/cursor management
(`SolveMatMulNonceSeeded`, the PR #72 patch) that btxd's `generatetoaddress` cadence happens
to avoid. Implications:
- matador-miner correctly defaults overlap OFF (synchronous, ~150k nonces/sec, saturates GPU).
- The overlap's TRUE value at v3 is still unmeasured cleanly (can't run it standalone; a
  clean btxd async=0-vs-1 A/B needs 2 restarts/warmups).
- Confounded hint: btxd async=1 (16.8k digest @571W) vs solve-bench async=0 (~14.8k digest,
  power unknown) ~ +13%, so it MIGHT be >3% - the user's "seemed like a big deal" instinct
  may be right. Needs a clean same-power same-process number to confirm.
- This is also a latent bug in PR #72 upstream (stalls for any non-btxd caller).

## WIN #1: overlap recovered via launch serialization (+29%)

`CUDA_LAUNCH_BLOCKING=1` un-stalls `async=1`. Clean same-process, same-session A/B:

| config | nonces/sec | vs serial |
|---|---|---|
| async=0 (serial) | 150,478 | - |
| async=1 + CUDA_LAUNCH_BLOCKING=1 | **194,169** | **+29.0%** |

ROOT CAUSE: the overlap launches GPU work from two threads (main: prehash/prepare;
`std::async`: digest). Concurrent *asynchronous* CUDA launches race the context and hang
(7% util). `CUDA_LAUNCH_BLOCKING=1` serializes the LAUNCHES (host-side CPU prepare still
overlaps the GPU digest across threads) -> race gone, full overlap benefit. GPU sat ~65%
during the blocking run, so a TARGETED fix (mutex/stream around just the two overlapping
launches, instead of global blocking) may push even higher than +29%.

FIX (matador-miner): `--overlap` sets `BTX_MATMUL_PIPELINE_ASYNC=1` + `CUDA_LAUNCH_BLOCKING=1`.
BYTE-EXACT: CONFIRMED on this build via btx-matmul-overlap-ab (PR #72 harness, rebuilt).
Same v3 job serial vs overlap with CUDA_LAUNCH_BLOCKING=1 (shipped config): 24/24 found
(nonce64,digest) pairs IDENTICAL -> "RESULT: BYTE-EXACT IDENTICAL". Use the PR params
(--n 256 --nbits 0x207fffff --tries 48 ...); easy nbits + huge --tries floods CollectFinds
(one SolveMatMul per find) and looks like a stall (it is just slow + buffered stdout).
Overlap is now DEFAULT ON for CUDA in matador-miner v0.1.1 (validated, not inferred).
TODO upstream: PR #72 needs the same launch-serialization guard or it stalls for non-btxd callers.

### Notes / ruled out at the instruction level (SASS-verified, do not retry)
- nvcc already emits `LOP3` for every SHA Ch/Maj/sigma (10,012 in the binary) and
  `SHF` for every rotation (18,070). Hand-written LOP3/funnelshift buys nothing.
- windowed-SHA, seed/template midstates, M31 shift-reduction: upstreamed/optimal.
- occupancy patch (`__launch_bounds__` + unroll): REJECTED earlier (-40%, ALU-bound).
- async overlap pipeline: ~3% live at v3 (digest dominates), and stalls the
  standalone direct-call path -> matador-miner defaults overlap OFF.

## Pool mode (stratum) - WORKING

matador-miner `--mode pool` validated live against minebtx.com:3333: v18 handshake
(subscribe declares `protocol_compliant:["pre_hash_block_tier_v18"]`, else 401) ->
jobs -> solve at +31% overlap (~20k nonce/s) -> submit -> **ACCEPTED (0 rejects)**.
Reuses SolveMatMul with share_target_override = notify param[6], parent_mtp from the
job obj; nBits = param[5] is the loose pre-hash gate (matches killsquad client + pow.h).
Endianness: prevhash/merkle/target via uint256::FromHex as-is, NO reversal (confirmed
vs thekillsquad007 stratum_protocol.cpp). FIX that unblocked accepted shares: pool
rejected "ntime drift Ns exceeds window" because SolveMatMul refreshes nTime mid-search
(solo-correct). Pinned it in pool mode via BTX_MINER_HEADER_TIME_REFRESH_ATTEMPTS=
UINT32_MAX (can't use 0 - ResolveMinerHeaderTimeRefreshAttempts requires >0). Solo
keeps fresh-time. TODO: pool-mode dev-fee (time-based pool-account switch, Claymore-style).
