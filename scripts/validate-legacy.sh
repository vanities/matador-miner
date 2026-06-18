#!/usr/bin/env bash
# validate-legacy.sh — validate a legacy matador build on real Pascal/Volta/Turing hardware
# via Vast.ai. The pool re-validates every share, so accepted shares == correct PoW for that
# arch. Watches for the CPU-fallback failure (cuda_unavailable_fallback_to_cpu:..._too_old).
#
# Point it at the published legacy asset, then run:
#   LEGACY_URL="https://github.com/vanities/matador-miner/releases/download/<tag>/<asset>" \
#     bash scripts/validate-legacy.sh
#   # or, if the asset follows the "<tag>-linux-x86_64" naming:
#   LEGACY_TAG=v0.4.13-legacy-rc1 bash scripts/validate-legacy.sh
#
# Two cards per architecture (legacy binary has separate cubins per arch -> validate each).
set -uo pipefail
cd "$(dirname "$0")/.."

: "${LEGACY_URL:=}" "${LEGACY_TAG:=}"
if [ -z "$LEGACY_URL" ] && [ -z "$LEGACY_TAG" ]; then
  echo "set LEGACY_URL=<full asset url>  (or LEGACY_TAG=<tag> for the <tag>-linux-x86_64 scheme)" >&2
  exit 2
fi

OUT="bench-results/legacy-validate-$(date +%Y%m%d-%H%M%S).csv"
# longer window so slow old cards land enough shares to trust the verdict
export WARMUP=90 MEASURE=240 MAX_PRICE=1.0 LAUNCH_TIMEOUT=1400 OUT
export LEGACY_URL LEGACY_TAG

CARDS=("GTX 1080 Ti" "Titan Xp" "Tesla V100" "Titan V" "RTX 2080 Ti" "Tesla T4")
echo "[validate-legacy] asset: ${LEGACY_URL:-tag=$LEGACY_TAG}" >&2
echo "[validate-legacy] cards: ${CARDS[*]}" >&2
./scripts/vast-bench.sh "${CARDS[@]}"

echo
echo "=== LEGACY VALIDATION VERDICT (acc>0 + rej=0 = arch VALIDATED) ==="
awk -F, '
function arch(g){ if(g~/1080|1070|Titan Xp|1060/)return "Pascal"; if(g~/V100|Titan V/)return "Volta"; if(g~/2080|2060|Titan RTX|T4|RTX [468]000/)return "Turing"; return "?" }
NR==1{next}
$3 ~ /^[0-9]/ {
  v=($9+0>0 && $10+0==0)?"VALIDATED":(($10+0>0)?"REJECTS-correctness-bug":(($3+0==0)?"CPU-FALLBACK (0 nonce/s)":"no shares yet"));
  printf "%-14s %-7s nonce/s=%-6s util=%-4s acc=%-3s rej=%-3s -> %s\n",$1,arch($1),$3,$7"%",$9,$10,v
}' "$OUT" | sort -k2
echo "(full csv: $OUT)"
