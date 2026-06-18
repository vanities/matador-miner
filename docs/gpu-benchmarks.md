# BTX MatMul GPU benchmarks

Full results of benchmarking matador-miner across rented GPUs. The main
[README](../README.md#measured-rates) shows a curated subset; this is the complete list.

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
snapshots from June 2026 and float with the marketplace; all cards ran at 90-100% GPU util with
0 rejected shares.

## All NVIDIA GPUs (June 2026, sorted by efficiency = nonce/s per watt)

| GPU | nonce/s | Power | nonce/s per W | Vast $/hr | value |
|---|--:|--:|--:|--:|--:|
| L4 | 3.6k | ~69W | ~51 | ~0.31 | **11.6** |
| RTX PRO 6000 WS | 15.2k | ~294W | ~51 | ~1.01 | **15.0** |
| RTX PRO 4500 | 10.0k | ~197W | ~50 | ~0.37 | **27.1** |
| RTX 4070 Ti | 6.8k | ~135W | ~50 | ~0.15 | **45.8** |
| RTX PRO 6000 S | 17.7k | ~360W | ~49 | ~1.00 | **17.7** |
| RTX PRO 4000 | 6.7k | ~142W | ~46 | ~0.28 | **23.3** |
| RTX PRO 5000 | 12.3k | ~280W | ~43 | ~0.60 | **20.4** |
| RTX 5000 Ada | 9.9k | ~232W | ~42 | ~0.43 | **23.2** |
| RTX 4070S | 8.4k | ~198W | ~42 | ~0.17 | **50.3** |
| RTX 5090 | 18.8k | ~452W | ~41 | ~0.40 | **47.1** |
| RTX 5070 Ti | 9.3k | ~223W | ~41 | ~0.19 | **48.0** |
| L40S | 14.1k | ~345W | ~40 | ~0.60 | **23.5** |
| RTX 5880 Ada | 10.6k | ~263W | ~40 | ~0.54 | **19.9** |
| L40 | 11.6k | ~292W | ~39 | ~0.47 | **24.7** |
| RTX 4080S | 9.7k | ~250W | ~38 | ~0.24 | **40.1** |
| RTX 4090 | 14.6k | ~382W | ~38 | ~0.33 | **43.7** |
| RTX 5060 | 3.9k | ~104W | ~37 | ~0.08 | **47.9** |
| RTX 4070 | 5.8k | ~159W | ~36 | ~0.17 | **33.4** |
| RTX 6000 Ada | 10.5k | ~290W | ~36 | ~0.54 | **19.7** |
| RTX 5060 Ti | 4.7k | ~129W | ~36 | ~0.09 | **49.9** |
| RTX 5070 | 6.5k | ~180W | ~36 | ~0.13 | **50.8** |
| RTX 4500 Ada | 7.2k | ~208W | ~34 | ~0.22 | **32.6** |
| H100 SXM | 11.8k | ~340W | ~34 | ~2.01 | **5.9** |
| H200 | 11.3k | ~339W | ~33 | ~2.83 | **4.0** |
| A10 | 4.8k | ~149W | ~32 | ~0.30 | **16.0** |
| RTX 4080 | 9.5k | ~297W | ~31 | ~0.24 | **39.4** |
| RTX 4060 Ti | 4.4k | ~140W | ~31 | ~0.09 | **48.6** |
| A100 PCIE | 7.5k | ~238W | ~31 | ~0.54 | **14.0** |
| A100 SXM4 | 7.1k | ~232W | ~30 | ~0.59 | **12.0** |
| RTX A2000 | 1.8k | ~67W | ~26 | ~0.07 | **25.8** |
| RTX A5000 | 5.0k | ~196W | ~25 | ~0.20 | **24.8** |
| RTX 3080 Ti | 6.8k | ~271W | ~25 | ~0.13 | **51.1** |
| RTX 3090 | 5.9k | ~247W | ~23 | ~0.13 | **44.5** |
| RTX 3080 | 5.8k | ~248W | ~23 | ~0.12 | **48.5** |
| RTX 3070 | 4.3k | ~188W | ~22 | ~0.07 | **63.1** |
| RTX A4000 | 2.7k | ~124W | ~22 | ~0.08 | **33.9** |
| RTX 3060 Ti | 3.4k | ~181W | ~18 | ~0.08 | **41.3** |
| A16 | 934 | ~52W | ~17 | ~0.13 | **7.0** |
| RTX 3090 Ti | 7.6k | ~430W | ~17 | ~0.17 | **43.7** |
| H100 NVL | 8.3k | ~483W | ~17 | ~2.12 | **3.9** |
| RTX 3060 | 1.5k | ~105W | ~13 | ~0.05 | **29.2** |
| RTX 4060 | 3.3k | n/a | n/a | ~0.11 | **30.8** |

## Apple Silicon

| GPU | Backend | nonce/s |
|---|---|--:|
| Apple M4 Max | Metal | ~1.1k-1.3k |

## Takeaways

- **Consumer cards win on value by 2-4x.** This PoW is integer/ALU work, so the
  AI-datacenter premium (A100, H100, RTX 6000) buys tensor cores it cannot use.
- **Best value:** RTX 3070, RTX 5070, RTX 4070S.
- **Best efficiency** (nonce/W): L4 (~52), RTX PRO 6000 WS (~51), RTX 4070 Ti (~50).
- **Best raw throughput:** RTX 5090 (18.8k), RTX PRO 6000 S (17.7k), RTX 4090 (14.6k).

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
