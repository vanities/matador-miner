#!/usr/bin/env bash
# vast-sweep.sh — run vast-bench across ALL supported Vast.ai GPU models in batches
# of 10 (keeps log-polling responsive + concurrency modest), then merge into one CSV.
set -u
cd "$(dirname "$0")/.."
export MAX_PRICE="${MAX_PRICE:-4.0}" WARMUP="${WARMUP:-90}" MEASURE="${MEASURE:-60}" LAUNCH_TIMEOUT="${LAUNCH_TIMEOUT:-1000}"

B1=("RTX 3060 Ti" "RTX 3070" "RTX 3080" "RTX 3080 Ti" "RTX 3090 Ti" "RTX 4060" "RTX 4060 Ti" "RTX 4070" "RTX 4070 Ti" "RTX 4070S")
B2=("RTX 4080" "RTX 4080S" "RTX 5060" "RTX 5060 Ti" "RTX 5070" "RTX 5070 Ti" "RTX 5080" "RTX A2000" "RTX A4000" "RTX A5000")
B3=("RTX A6000" "RTX 4500Ada" "RTX 5000Ada" "RTX 5880Ada" "RTX PRO 4000" "RTX PRO 4500" "RTX PRO 5000" "RTX PRO 6000 S" "RTX PRO 6000 WS" "A10")
B4=("A16" "A100 PCIE" "L4" "L40" "L40S" "H100 SXM" "H100 NVL" "H200" "H200 NVL" "RTX 3060 laptop")

merged="bench-results/sweep-merged-$(date +%Y%m%d-%H%M%S).csv"
i=0
for batch in B1 B2 B3 B4; do
  i=$((i+1))
  eval "cards=(\"\${$batch[@]}\")"
  echo "######## BATCH $i/4: ${cards[*]} ########" >&2
  OUT="bench-results/sweep-b$i.csv" ./scripts/vast-bench.sh "${cards[@]}"
done

# merge: header from b1, data rows from all
{ head -1 bench-results/sweep-b1.csv; for f in bench-results/sweep-b*.csv; do tail -n +2 "$f"; done; } > "$merged"
echo "######## MERGED -> $merged ########" >&2
echo; echo "=== ALL MODELS ranked by value (k nonce/s per \$/hr) ==="
{ echo "gpu,nonce_per_s,watts,nonce_per_W,vast_dph,k_nps_per_dph";
  tail -n +2 "$merged" | awk -F, '$3 ~ /^[0-9]/ {printf "%s,%d,%s,%s,%s,%.1f\n",$1,$3,$5,$6,$11,($3/$11)/1000}' \
  | sort -t, -k6 -nr; } | column -t -s,
