# BTX MatMul GPU benchmarks

Full results of benchmarking matador-miner across rented GPUs. The main
[README](../README.md#measured-rates) shows a curated subset; this is the complete list.

> **Measured on v0.6.8** (current stable release), June 2026. These supersede the earlier
> pre-v0.5.0 numbers: throughput is up roughly **1.5x-2.0x** - e.g. the
> RTX 5090 went from 18.8k to **32.3k nonce/s**. Reproduce, or pin the same build, with
> `BVERSION=v0.6.8 ./scripts/vast-bench.sh`.

> Want to sort by any column? Open [`gpu-benchmarks.csv`](gpu-benchmarks.csv) - GitHub renders
> CSV files as a sortable, searchable table (the Markdown tables below are static).

**Method:** each GPU is rented on [Vast.ai](https://vast.ai), runs `matador-miner --mode pool`
against the minebtx pool at stock power for a short steady-state window, and is then destroyed.
Numbers are scraped from matador's own `[stats]` line (peak steady-state `nonce/s`) plus
`nvidia-smi` (power/util). Reproduce with [`scripts/vast-bench.sh`](../scripts/vast-bench.sh):

```bash
./scripts/vast-bench.sh "RTX 5090" "RTX 4090"     # specific cards
./scripts/vast-bench.sh                            # default ladder
DRY_RUN=1 ./scripts/vast-bench.sh                  # search + cost estimate only
```

Sorted by **efficiency** (`nonce/s per W`) - the metric to optimize on owned hardware. The
`value` column (thousands of nonce/s per Vast `$/hr`) is the rental angle. Only hosts with >=8
effective vCPU are used (fewer starve the GPU and tank the rate). Vast `$/hr` are per-offer
snapshots from June 2026 and float with the marketplace; cards ran at ~80-100% GPU util with
0 rejected shares.

## All NVIDIA GPUs (v0.6.8, June 2026, sorted by efficiency = nonce/s per watt)

| GPU | nonce/s | Power | nonce/s per W | Vast $/hr | value |
|---|--:|--:|--:|--:|--:|
| L4 | 5.8k | ~72W | ~81 | ~0.31 | **18.8** |
| RTX PRO 4000 | 10.6k | ~141W | ~75 | ~0.21 | **50.0** |
| RTX PRO 4500 | 14.6k | ~195W | ~75 | ~0.34 | **43.7** |
| RTX PRO 6000 S | 35.1k | ~549W | ~64 | ~1.14 | **30.9** |
| L40S | 21.4k | ~344W | ~62 | ~1.14 | **18.8** |
| RTX PRO 6000 WS | 36.4k | ~598W | ~61 | ~0.94 | **38.8** |
| L40 | 17.5k | ~292W | ~60 | ~0.46 | **38.3** |
| RTX 5090 | 32.3k | ~577W | ~56 | ~0.39 | **83.2** |
| H100 NVL | 16.2k | ~300W | ~54 | ~1.94 | **8.4** |
| RTX 4090 | 21.6k | ~413W | ~52 | ~0.35 | **62.1** |
| RTX 4080S | 14.4k | ~282W | ~51 | ~0.20 | **71.9** |
| RTX 5070 Ti | 15.1k | ~298W | ~51 | ~0.16 | **93.1** |
| RTX 4080 | 14.6k | ~291W | ~50 | ~0.34 | **43.5** |
| RTX 4070S | 8.4k | ~173W | ~48 | ~0.14 | **61.8** |
| RTX A4000 | 4.8k | ~99W | ~48 | ~0.08 | **63.0** |
| RTX 5060 Ti | 7.9k | ~164W | ~48 | ~0.08 | **102.2** |
| RTX 5060 | 6.5k | ~138W | ~47 | ~0.08 | **79.9** |
| A10 | 7.1k | ~149W | ~47 | ~0.30 | **23.4** |
| RTX 4070 Ti | 9.3k | ~200W | ~46 | ~0.24 | **38.5** |
| H200 | 17.1k | ~370W | ~46 | ~2.95 | **5.8** |
| RTX 4070 | 8.7k | ~191W | ~46 | ~0.29 | **30.3** |
| RTX 5070 | 10.6k | ~238W | ~45 | ~0.17 | **60.9** |
| A100 PCIE | 11.1k | ~247W | ~45 | ~0.52 | **21.2** |
| A100 SXM4 | 10.9k | ~250W | ~44 | ~0.55 | **19.8** |
| RTX 4060 Ti | 6.5k | ~155W | ~42 | ~0.09 | **71.7** |
| H100 SXM | 15.8k | ~383W | ~41 | ~1.92 | **8.2** |
| RTX A2000 | 2.8k | ~68W | ~41 | ~0.07 | **41.0** |
| RTX PRO 5000 | 5.8k | ~142W | ~41 | ~0.54 | **10.8** |
| RTX A5000 | 7.6k | ~200W | ~38 | ~0.16 | **46.6** |
| RTX 3060 | 2.2k | ~64W | ~34 | ~0.06 | **39.9** |
| RTX 3060 Ti | 4.7k | ~147W | ~32 | ~0.07 | **67.0** |
| RTX 3090 | 9.1k | ~296W | ~31 | ~0.13 | **70.2** |
| RTX 3070 | 6.2k | ~232W | ~27 | ~0.09 | **71.1** |
| RTX 3090 Ti | 10.7k | ~413W | ~26 | ~0.20 | **53.4** |

> **Omitted this run:** RTX 3080 and RTX 3080 Ti (only clock/power-limited Vast offers were
> available - scan rate ~half of what the silicon should do, which would understate the cards),
> and RTX 5000 Ada, RTX 5880 Ada, RTX 6000 Ada, RTX 4500 Ada, A16, RTX 4060 (no Vast inventory at
> bench time). They return to the table when clean offers do.

## Apple Silicon

| GPU | Backend | nonce/s |
|---|---|--:|
| Apple M4 Max | Metal | ~1.1k-1.3k |

> Measured live on **v0.7.0**, which mines on the **Metal GPU** (earlier macOS builds ran on the
> CPU at a similar rate); 0 rejected shares.

## Takeaways

- **Consumer cards win on value by 2-4x.** This PoW is integer/ALU work, so the
  AI-datacenter premium (A100, H100, RTX 6000) buys tensor cores it cannot use.
- **Best value** (nonce/s per $/hr): RTX 5060 Ti, RTX 5070 Ti, RTX 5090.
- **Best efficiency** (nonce/W): L4 (~81), RTX PRO 4000 (~75), RTX PRO 4500 (~75).
- **Best raw throughput:** RTX PRO 6000 WS (36.4k), RTX PRO 6000 S (35.1k), RTX 5090 (32.3k).

## AMD

Not measured: Vast.ai had **zero AMD GPUs** in inventory across all offers at the time. The
AMD path (HIP/ROCm via the [`amdbtx`](https://github.com/thekillsquad007/amdbtx) sidecar) needs
either AMD inventory to return to Vast or a different provider (RunPod / TensorDock list MI300X).

## Legacy GPUs (Pascal / Volta / Turing)

**Status: the `v0.4.13` legacy build (`sm_60/61/70/75`, CUDA 12.8) is VALIDATED on real
hardware** (Vast, June 2026). The pool re-validates every share, so accepted shares == correct
PoW for that architecture. All three arches landed accepted shares with 0 rejects:

| GPU | arch | nonce/s | Power | nonce/s per W | acc/rej | verdict |
|---|---|--:|--:|--:|--:|---|
| GTX 1080 Ti | Pascal `sm_61` | ~2.4k | ~158W | ~15 | 9 / 0 | VALIDATED |
| Titan Xp | Pascal `sm_61` | ~2.3k | ~145W | ~16 | 2 / 0 | VALIDATED |
| Titan V | Volta `sm_70` | ~4.9k | ~154W | ~32 | 3 / 0 | VALIDATED |
| Tesla T4 | Turing `sm_75` | ~2.2k | ~65W | ~34 | 2 / 0 | VALIDATED |

**No config needed.** The CUDA backend gate defaults to a minimum of `sm_80` (Ampere) and would
fall back to CPU on older cards, but the `-legacy` build auto-enables the older-GPU path itself
(it sets `BTX_CUDA_ALLOW_OLDER_GPUS` internally, lowering the floor to `sm_60`). Validated above
on real Pascal/Volta/Turing with no env var set. `install.sh` auto-routes old GPUs to this build.

The older `v0.4.9-legacy` asset is non-functional on this hardware (kernels run but produce 0
nonces - missing/incomplete cubins) and is superseded by `v0.4.13`. Re-validate any legacy build
with [`scripts/validate-legacy.sh`](../scripts/validate-legacy.sh) (set `LEGACY_URL` to its asset).
