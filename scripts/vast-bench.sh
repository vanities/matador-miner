#!/usr/bin/env bash
# vast-bench.sh — rent GPUs on Vast.ai, run matador-miner against the pool for a
# short window, and report AVERAGE watts + AVERAGE hashes/sec (and hashes/watt)
# per card, ranked.
#
# WHAT IT DOES (per requested GPU model):
#   1. picks the cheapest reliable single-GPU offer whose host driver can run our
#      binary, and auto-selects the MAIN (Ampere+) or LEGACY (Pascal/Volta/Turing)
#      matador build from the card's compute capability
#   2. launches an instance: installs matador, mines the pool for WARMUP+MEASURE s,
#      sampling power every 5s and nonce totals at both ends of the window
#   3. polls logs for the sentinels, computes avg W / avg hash-s / hash-per-W
#   4. DESTROYS the instance
#
# SAFETY: every instance created here is destroyed on exit (trap), so Ctrl-C never
# leaves a paid box running. Sanity-check with `vastai show instances`.
#
# USAGE:
#   ./scripts/vast-bench.sh                          # default ladder
#   ./scripts/vast-bench.sh "RTX 5090" "RTX 4090"    # explicit models
#   DRY_RUN=1 ./scripts/vast-bench.sh                # search + cost only, create nothing
#   ./scripts/vast-bench.sh "RTX 2080 Ti" "GTX 1080 Ti"   # legacy auto-selected
#
# ENV KNOBS [default]:
#   WARMUP=90  MEASURE=60   warmup then measure-window seconds
#   MAX_PRICE=2.0           skip offers above this $/hr
#   MIN_RELIABILITY=0.90    host reliability floor
#   MIN_CPU=8               min effective vCPU threads (cheap 1-vCPU hosts starve the GPU)
#   IMAGE / IMAGE_LEGACY    CUDA base images (main=CUDA13, legacy=CUDA12.8)
#   POOL                    stratum URL
#   DISK=16  PWR_INTERVAL=5  LAUNCH_TIMEOUT=1200
#   DRY_RUN=1               estimate only
#   LABEL_PREFIX            Vast dashboard label prefix [matador-test]
#   OUT                     CSV path [bench-results/vast-<ts>.csv]
#
# NB: legacy build is EXPERIMENTAL/UNVALIDATED for matmul PoW correctness on Pascal.
#     Cards with compute_cap outside {600,610,700,750, 800,860,890,900,1200}
#     are skipped (Vast reports cap x100; e.g. B200 sm_100=1000 is in neither binary).
set -uo pipefail
cd "$(dirname "$0")/.."

WARMUP="${WARMUP:-90}"
MEASURE="${MEASURE:-60}"
MAX_PRICE="${MAX_PRICE:-2.0}"
MIN_RELIABILITY="${MIN_RELIABILITY:-0.90}"
MIN_CPU="${MIN_CPU:-8}"   # min effective vCPU threads; pool flags <6 as host-starved -> bogus rates
# Ubuntu 24.04 base: matador needs GLIBC 2.38 / GLIBCXX 3.4.32 (22.04 ships 2.35 — too old).
IMAGE="${IMAGE:-nvidia/cuda:13.0.1-runtime-ubuntu24.04}"
IMAGE_LEGACY="${IMAGE_LEGACY:-nvidia/cuda:12.8.1-runtime-ubuntu24.04}"
POOL="${POOL:-stratum+tcp://stratum.minebtx.com:3333}"
DISK="${DISK:-16}"
PWR_INTERVAL="${PWR_INTERVAL:-5}"
LAUNCH_TIMEOUT="${LAUNCH_TIMEOUT:-1200}"
DRY_RUN="${DRY_RUN:-0}"
OUT="${OUT:-bench-results/vast-$(date +%Y%m%d-%H%M%S).csv}"
LEGACY_TAG="${LEGACY_TAG:-v0.4.9-legacy}"
# Asset name defaults to "<tag>-linux-x86_64" (the v0.4.9-legacy scheme). For the newer
# "<version>-legacy" naming, set LEGACY_ASSET, or just set LEGACY_URL to the full download URL.
LEGACY_ASSET="${LEGACY_ASSET:-matador-miner-${LEGACY_TAG}-linux-x86_64}"
LEGACY_URL="${LEGACY_URL:-https://github.com/vanities/matador-miner/releases/download/${LEGACY_TAG}/${LEGACY_ASSET}}"

# default ladder: cheap -> flagship (5080 + H100 dropped per request)
DEFAULT_GPUS=("RTX 3060" "RTX 3090" "RTX 4090" "RTX 6000Ada" "RTX 5090" "A100 SXM4")
GPUS=("$@"); [ ${#GPUS[@]} -eq 0 ] && GPUS=("${DEFAULT_GPUS[@]}")

log(){ printf '[vast-bench %s] %s\n' "$(date +%T)" "$*" >&2; }
die(){ printf '[vast-bench] ERROR: %s\n' "$*" >&2; exit 1; }

[ -f .env ] && { set -a; . ./.env; set +a; }
[ -n "${VAST_API_KEY:-}" ] || die "VAST_API_KEY not set (put it in .env)"
command -v vastai >/dev/null || die "vastai CLI not found (uv tool install vastai)"
PAYOUT="$(grep -oE 'btx1[a-z0-9]+' address.txt | head -1)"
[ -n "$PAYOUT" ] || die "no btx1... payout address in address.txt"
mkdir -p "$(dirname "$OUT")"

declare -a CREATED=()
cleanup(){
  [ ${#CREATED[@]} -eq 0 ] && return
  log "cleanup: destroying ${#CREATED[@]} instance(s): ${CREATED[*]}"
  for id in "${CREATED[@]}"; do [ -n "$id" ] || continue
    vastai destroy instance "$id" -y >/dev/null 2>&1 && log "  destroyed $id" || log "  FAILED destroy $id — CHECK 'vastai show instances-v1'"
  done
}
trap cleanup EXIT INT TERM

# onstart: $VARS expand on the instance (passed via --env). BLEGACY/BLEGACY_URL pick the binary.
read -r -d '' ONSTART <<'ONSTART_EOF' || true
set -u
export DEBIAN_FRONTEND=noninteractive
echo "BENCH_BOOT $(date -u +%FT%TZ)"
apt-get update -qq >/dev/null 2>&1 || true
apt-get install -y -qq curl ca-certificates coreutils >/dev/null 2>&1 || true
retry(){ # retry a command up to 5x with backoff — tolerates flaky host networking
  local a; for a in 1 2 3 4 5; do
    if "$@"; then return 0; fi
    echo "BENCH_RETRY attempt $a: $*"; sleep $((a*8))
  done; return 1
}
if [ "${BLEGACY:-0}" = "1" ]; then
  echo "BENCH_BIN legacy"
  # NOTE: do NOT set BTX_CUDA_ALLOW_OLDER_GPUS here - the legacy build self-enables the
  # older-GPU path with zero config. Set BLEGACY_ALLOW_ENV=1 to force it (e.g. testing old assets).
  [ "${BLEGACY_ALLOW_ENV:-0}" = "1" ] && export BTX_CUDA_ALLOW_OLDER_GPUS=1
  retry curl -fsSL "$BLEGACY_URL" -o /usr/local/bin/matador-miner || { echo "BENCH_FAIL legacy-dl"; exit 0; }
  curl -fsSL "$BLEGACY_URL.sha256" -o /tmp/m.sha256 2>/dev/null && \
    ( cd /usr/local/bin && awk '{print $1"  matador-miner"}' /tmp/m.sha256 | sha256sum -c - ) || echo "BENCH_WARN sha-skip"
  chmod +x /usr/local/bin/matador-miner
else
  echo "BENCH_BIN main"
  install_main(){ curl -fsSL https://raw.githubusercontent.com/vanities/matador-miner/main/install.sh | PREFIX=/usr/local/bin bash; }
  retry install_main || { echo "BENCH_FAIL install"; exit 0; }
fi
# BBACKEND=cuda (default) passes --backend cuda; BBACKEND=auto OMITS the flag to test the
# binary's auto-detect path. (Older builds defaulted to CPU with no flag - hence the explicit default.)
BFLAG="--backend ${BBACKEND:-cuda}"; [ "${BBACKEND:-}" = "auto" ] && BFLAG=""
matador-miner --mode pool $BFLAG --pool "$BPOOL" --worker "$BWORKER" \
  --payoutaddress "$BPAYOUT" --api --api-port 4060 >/var/log/matador.log 2>&1 &
MPID=$!
echo "BENCH_START warmup=${BWARMUP}s measure=${BMEASURE}s"
hb(){ # heartbeat so a hang is visible instead of silent
  a=$(kill -0 "$MPID" 2>/dev/null && echo up || echo DEAD)
  api=$(curl -sf localhost:4060/summary >/dev/null 2>&1 && echo up || echo down)
  smi=$(nvidia-smi --query-gpu=utilization.gpu,power.draw --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
  last=$(tail -1 /var/log/matador.log 2>/dev/null | cut -c1-110)
  echo "BENCH_HB $1 mm=$a api=$api smi=[$smi] log=[$last]"
}
# wait for API (~180s) with heartbeats
for i in $(seq 1 36); do curl -sf localhost:4060/summary >/dev/null 2>&1 && break; hb "wait$((i*5))s"; sleep 5; done
echo "MM_LOG_START"; grep -aE 'backend|RESOLVED|CUDA|cuda|GPU|gpu_inputs|overlap|error|Error|WARN|nonce/s|nvml|driver|pool|stratum|connect|job' /var/log/matador.log 2>/dev/null | head -50; echo "MM_LOG_END"
# warmup with heartbeats
we=$(( $(date +%s) + BWARMUP ))
while [ "$(date +%s)" -lt "$we" ]; do hb "warm"; sleep "${BHB:-6}"; done
ME=$(( $(date +%s) + BMEASURE ))
while [ "$(date +%s)" -lt "$ME" ]; do
  echo "BENCH_PWR $(nvidia-smi --query-gpu=power.draw,utilization.gpu,temperature.gpu --format=csv,noheader,nounits 2>/dev/null | head -1)"
  sleep "${BPWR_INTERVAL:-5}"
done
# matador's own [stats] lines (short, single-line, robust): nonce/s, scan rate, shares
echo "BENCH_STATS_BEGIN"; grep -aE '\[stats\]' /var/log/matador.log 2>/dev/null | tail -6; echo "BENCH_STATS_END"
echo "BENCH_DONE"
kill "$MPID" 2>/dev/null || true
ONSTART_EOF

# find cheapest VIABLE offer for a gpu: supported compute_cap, host driver new enough,
# AND enough effective CPU to feed the GPU (cheap 1-vCPU hosts starve the miner -> bogus rates;
# minebtx pool flags this as "host-starved, class minimum 6 threads"). echoes:
# "offer_id dph compute_cap is_legacy cpu_effective"
find_offer(){
  local gpu="$1"
  vastai search offers \
    "rentable=true num_gpus=1 reliability>$MIN_RELIABILITY dph_total<$MAX_PRICE cpu_cores_effective>=$MIN_CPU gpu_name=\"$gpu\"" \
    --order 'dph_total' --raw --limit 80 2>/dev/null \
  | python3 -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit()
d=[o for o in d if o.get('gpu_name')=='$gpu']
# Vast reports compute_cap as x100: sm_89->890, sm_90->900, sm_120->1200, sm_75->750
LEGACY={600,610,700,750}; MAIN={800,860,890,900,1200}
def need(cc): return 12.8 if cc in LEGACY else 13.0
for o in sorted(d,key=lambda x:x.get('dph_total') or 9e9):
    cc=int(o.get('compute_cap') or 0)
    if cc not in LEGACY and cc not in MAIN: continue          # unsupported arch
    try: drv=float(o.get('cuda_max_good') or 0)
    except: drv=0
    if drv < need(cc): continue                                # host driver too old for our binary
    cpu=float(o.get('cpu_cores_effective') or 0)
    if cpu < $MIN_CPU: continue                                # not enough CPU to feed the GPU
    print(o['id'], round(o.get('dph_total') or 0,3), cc, 1 if cc in LEGACY else 0, round(cpu,1)); break
"
}

log "payout=${PAYOUT:0:12}…  pool=$POOL  warmup=${WARMUP}s measure=${MEASURE}s"
log "cards: ${GPUS[*]}"
declare -A GNAME GPRICE
est=0
for gpu in "${GPUS[@]}"; do
  read -r oid dph cc leg cpu < <(find_offer "$gpu")
  if [ -z "${oid:-}" ]; then log "SKIP '$gpu': no viable offer (<\$$MAX_PRICE, rel>$MIN_RELIABILITY, ${MIN_CPU}+ vCPU, supported arch + driver)"; continue; fi
  tag="main"; img="$IMAGE"; [ "$leg" = "1" ] && { tag="LEGACY"; img="$IMAGE_LEGACY"; }
  log "found '$gpu': offer $oid @ \$$dph/hr  sm_$cc  cpu=${cpu}t  [$tag]"
  est=$(python3 -c "print($est + $dph)")
  [ "$DRY_RUN" = "1" ] && continue
  label="${LABEL_PREFIX:-matador-test}-$(echo "$gpu" | tr ' ' '-' | tr -cd '[:alnum:]-')"
  worker="$label"   # same name on the pool dashboard (pool.minebtx.com) as the Vast label
  out="$(vastai create instance "$oid" --image "$img" --disk "$DISK" --label "$label" \
        --onstart-cmd "$ONSTART" \
        --env "-e BPOOL=$POOL -e BWORKER=$worker -e BPAYOUT=$PAYOUT -e BWARMUP=$WARMUP -e BMEASURE=$MEASURE -e BPWR_INTERVAL=$PWR_INTERVAL -e BLEGACY=$leg -e BLEGACY_URL=$LEGACY_URL" \
        --raw 2>&1)"
  iid="$(printf '%s' "$out" | python3 -c "import sys,json;print(json.load(sys.stdin).get('new_contract',''))" 2>/dev/null)"
  [ -z "$iid" ] && { log "  create FAILED '$gpu': $out"; continue; }
  CREATED+=("$iid"); GNAME["$iid"]="$gpu"; GPRICE["$iid"]="$dph"
  log "  launched '$gpu' -> instance $iid ($tag)"
done

per_card_hr=$(python3 -c "print(($WARMUP+$MEASURE+300)/3600)")
log "est cost ceiling ~\$$(python3 -c "print(round($est*$per_card_hr,2))") (boot+pull ~5min each)"
[ "$DRY_RUN" = "1" ] && { log "DRY_RUN=1 — nothing launched."; exit 0; }
[ ${#CREATED[@]} -eq 0 ] && die "no instances launched"

echo "gpu,binary,nonce_per_s,scan_mnps,avg_watts,nonce_per_watt,avg_util_pct,avg_temp_c,accepted,rejected,dph,stale" > "$OUT"
deadline=$(( $(date +%s) + LAUNCH_TIMEOUT ))
declare -A DONE
while :; do
  pending=0
  for iid in "${CREATED[@]}"; do
    [ -n "$iid" ] || continue
    [ -n "${DONE[$iid]:-}" ] && continue
    pending=1
    logs="$(vastai logs "$iid" 2>/dev/null)"
    if printf '%s' "$logs" | grep -q 'BENCH_DONE'; then
      log "RESULT '${GNAME[$iid]}' (instance $iid) — parsing + destroying"
      printf '%s' "$logs" | GPU="${GNAME[$iid]}" DPH="${GPRICE[$iid]}" python3 -c '
import sys,os,re
txt=sys.stdin.read(); gpu=os.environ["GPU"]; dph=os.environ["DPH"]
binr="legacy" if "BENCH_BIN legacy" in txt else "main"
# matador [stats] line: "... acc=A rej=R ... nonce/s=N scan=X.XMN/s" — take the last (steady state)
stats=re.findall(r"acc=(\d+) rej=(\d+) stale=(\d+).*?nonce/s=(\d+).*?scan=([\d.]+)MN/s", txt)
pw=[];ut=[];tp=[]
for line in re.findall(r"BENCH_PWR ([0-9.,\s]+)",txt):
    parts=[p.strip() for p in line.split(",")]
    try:
        pw.append(float(parts[0]))
        if len(parts)>1: ut.append(float(parts[1]))
        if len(parts)>2: tp.append(float(parts[2]))
    except: pass
if not stats:
    print(f"{gpu},{binr},NO_STATS,,,,,,,,{dph}", file=sys.stderr); raise SystemExit
# nonce/s + scan from the PEAK line (avoids early-ramp under-reads on slow-boot hosts);
# acc/rej/stale from the LAST line (cumulative counters -> final totals, for correctness checks)
peak=max(stats, key=lambda t:int(t[3])); nps=int(peak[3]); scan=peak[4]
acc,rej,stale=stats[-1][0],stats[-1][1],stats[-1][2]
def mean(x): return sum(x)/len(x) if x else 0
w=mean(pw); hpw=nps/w if w else 0
print(f"{gpu},{binr},{nps},{scan},{w:.1f},{hpw:.2f},{mean(ut):.0f},{mean(tp):.0f},{acc},{rej},{dph},{stale}")
' >> "$OUT" 2>>"$OUT.err"
      vastai destroy instance "$iid" -y >/dev/null 2>&1 && log "  destroyed $iid"
      DONE[$iid]=1
    elif printf '%s' "$logs" | grep -qE 'BENCH_FAIL'; then
      log "  '${GNAME[$iid]}' BENCH_FAIL — destroying"
      echo "${GNAME[$iid]},?,BOOT_FAIL,,,,,,,,${GPRICE[$iid]}" >> "$OUT"
      vastai destroy instance "$iid" -y >/dev/null 2>&1; DONE[$iid]=1
    fi
  done
  [ "$pending" = "0" ] && break
  [ "$(date +%s)" -ge "$deadline" ] && { log "TIMEOUT ${LAUNCH_TIMEOUT}s — trap will destroy the rest"; break; }
  sleep 20
done

log "results -> $OUT"
echo; column -t -s, "$OUT" 2>/dev/null || cat "$OUT"
echo; log "ranked by nonce/watt:"; { head -1 "$OUT"; tail -n +2 "$OUT" | sort -t, -k6 -nr; } | column -t -s,
