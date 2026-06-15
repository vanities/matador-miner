# Go and Look

*Two models, one miner, the same question.*

I asked two models the same question. Find me optimizations for the miner. Same 5090, same code, same ask. I got two completely different answers.

Opus looked at it and told me there was nothing to find.

Not lazily. It did the homework. It read upstream's own optimization notes, saw they'd already done the warp-shuffle reduction, saw they'd tried CUDA graphs and layout rewrites and thrown them out. It checked the field math and called it already optimal, which it was. It looked at the tensor-core route and said not worth it, which was also right. Then it closed the case.

"Already at its frontier. The only real lever is a one-line GPU undervolt. Not a faster miner. The bottleneck is fixed by consensus."

So I pushed. Optimize this anyway. And it tuned the power. Locked the clocks, dropped the cap, got me to 346 watts at basically the same speed. A real win on nonces per watt. But it never touched the solver. It had already decided the solver was finished.

Then I asked Fable the same question.

Fable didn't buy the frontier.

It went into the kernels. First thing it turned up was a second copy of the SHA code sitting in the matrix-gen path that upstream never optimized. Opus read the notes and trusted them. Fable read the code and found the thing the notes didn't mention.

Then it kept going. A single-block reduction, +58%. Factored compression, where the weights fold into the product so you run 12 million multiplies instead of 134 million, +145%. Tiling, midstates, another +15%. Six patches, every one byte-exact on millions of elements. The miner ended up about 3x faster than the thing Opus called done.

Here's the part that settles it.

I shipped Fable's kernels to the upstream PR. The pool copied them into their own miner inside of a day. You don't copy code off a frontier. If Opus was right, there was nothing there to take. There was plenty.

And give Opus its due. It was right about the traps. Tensor cores are a rabbit hole, and Fable parked them for the same reason. The gap wasn't smarts. It was where they stopped.

Opus walked up to the cliff, read the sign that said fully explored, and turned around. Fable climbed down to check.

"Already optimized" is a claim. You verify it by reading the code yourself. One model took the sign at its word. The other went and looked.

I'll take the one that goes and looks.

— AM

---

## Sources / receipts

Pulled from the local Claude Code session transcripts in `~/.claude/projects/-Users-vanities-git-work-me-btx-miner/` and the project memory.

### The Opus run: session `92a03f6d` (claude-opus-4-7)

Asked to optimize the miner. Verbatim conclusions from the transcript:

> "already well-optimized for what it is (their biggest win was a 16% warp-shuffle reduction; CUDA graphs and layout rewrites were tried and *rejected*)."

> "already optimal." *(on the M31 field reduction: for p = 2³¹−1, a 62-bit product folds via `r = (x & 0x7FFFFFFF) + (x >> 31)`, applied twice)*

> "NOT worth it for you. Ozaki Scheme II (the state of the art for exact GEMM on INT8 tensor cores) needs ~16 INT8 matmuls to emulate one high-precision [multiply]."

> "not worth building/measuring. Bottleneck is per-solve latency/compute critical path, fixed by consensus."

> "already at its frontier — the only worthwhile lever was a one-line GPU undervolt, not a faster miner."

My pushback, verbatim user turn: **"optimize this anyway."**

What it delivered (logged in the efficiency memory, origin session `92a03f6d`): the GPU undervolt. `sudo nvidia-smi -lgc 0,2600 && -pl 520` → ~346 W at ~130.7K n/s ≈ 378 nonces/watt. A real efficiency win. The solver itself, untouched.

### The Fable run: session `d3e5fb09` (claude-fable-5)

Same ask, "look for more optimizations for my gpu." Found and shipped six byte-exact CUDA patches on the official 0.32.x solver:

| patch | what | A/B (median nonces/s) |
|---|---|---|
| `sha-windowed-matrixgen` + `fused-single-reduction` | the duplicate SHA in the matrix-gen path + single block reduction | 126,066 → 199,319 (**+58%**) |
| `factored-compression` | distribute compress weights over the block product (134M → ~12.6M MACs) | 198,114 → 485,967 (**+145%**) |
| 2×2 tiling + `template-midstate-scanner` | warp does a 2×2 word tile; block-0 SHA midstates | 488,981 → 564,473 (**+15%**) |
| `matrixgen-seed-midstate` | per-seed SHA midstate, rounds 0-7 hoisted | **+5.6%** |

Honest end-to-end, measured in v2 nonce-seed mode (the mode live mining actually uses): **clean 0.32.x = 54,964 → six patches = 163,699 n/s ≈ 2.98×.** Every patch validated byte-exact (2.1M+ matrix elements, retry/fallback edges, fused vs stock vs a CPU reference, 0 mismatches).

Both models rejected tensor cores / INT8 emulation as not worth the risk. Agreement there.

### The proof it wasn't a frontier

Upstreamed as **PR btxchain/btx#58**. The minebtx / DEXBTX pool adopted the kernels within a day. Their `btx-prebuilds-v0.32.5` release notes:

> "BTX v0.32.5 + PR58 GPU saturation kernels + C4 continuous feeding"

If the solver had been at its frontier, there'd have been nothing to copy.
