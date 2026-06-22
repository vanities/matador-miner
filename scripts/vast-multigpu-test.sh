#!/usr/bin/env bash
# vast-multigpu-test.sh — rent ONE multi-GPU box on Vast.ai and verify matador-miner's
# auto multi-GPU fan-out: it should detect every card (nvidia-smi --query-gpu=index),
# fork one child per GPU (worker <w>-gpu<dev>, API port base+i), drive ALL cards, and land
# shares with 0 rejects. Proves correctness + near-linear scaling, then DESTROYS the box.
#
# WHAT IT CHECKS (per the fan-out contract in matador-miner.cpp):
#   1. supervisor logs "[multi-gpu] auto-detected N GPUs ... mining on all" + N "spawned" lines
#   2. all N child APIs answer on 4060..4060+N-1 (mining_state=mining, backend=cuda)
#   3. every PHYSICAL gpu shows util/power on host nvidia-smi (not just gpu0)
#   4. per-GPU nonce/s (child API batched_attempts delta) + aggregate ~= N x per-GPU
#   5. accepted>0, rejected==0 across children
#
# SAFETY: the instance is destroyed on exit (trap), so Ctrl-C / failure never leaks a paid box.
#         Sanity-check with `vastai show instances-v1`.
#
# USAGE:
#   ./scripts/vast-multigpu-test.sh                 # default: cheapest viable >=4-GPU box
#   NGPU=8 ./scripts/vast-multigpu-test.sh          # require >=8 GPUs
#   DRY_RUN=1 ./scripts/vast-multigpu-test.sh       # search + cost only, create nothing
#   GPU_NAME="RTX 3090" ./scripts/vast-multigpu-test.sh   # pin the card model
#
# ENV KNOBS [default]:
#   NGPU=4                  minimum GPUs on the box
#   GPU_NAME=""             optional exact gpu_name filter (e.g. "RTX 3090")
#   WARMUP=90 MEASURE=60    warmup then measure-window seconds
#   MAX_PRICE=3.0           skip offers above this $/hr (whole box)
#   MIN_RELIABILITY=0.95    host reliability floor
#   MIN_CPU=<4*NGPU>        min effective vCPU threads (N children each need CPU to feed a GPU)
#   IMAGE                   CUDA base image [nvidia/cuda:13.0.1-runtime-ubuntu24.04]
#   POOL                    stratum URL
#   DISK=20 PWR_INTERVAL=5 LAUNCH_TIMEOUT=1500
#   LABEL                   Vast dashboard label [matador-mgpu]
#   OUT                     CSV path [bench-results/vast-mgpu-<ts>.csv]
set -uo pipefail
cd "$(dirname "$0")/.."

NGPU="${NGPU:-4}"
GPU_NAME="${GPU_NAME:-}"
WARMUP="${WARMUP:-90}"
MEASURE="${MEASURE:-60}"
MAX_PRICE="${MAX_PRICE:-3.0}"
MIN_RELIABILITY="${MIN_RELIABILITY:-0.95}"
MIN_CPU="${MIN_CPU:-$((4*NGPU))}"   # N children feed N GPUs; too few vCPU starves them -> bogus low rates
# v0.5.0+ runs on glibc 2.34+, so 22.04 or 24.04 both work; keep 24.04 (matches the bench suite).
IMAGE="${IMAGE:-nvidia/cuda:13.0.1-runtime-ubuntu24.04}"
POOL="${POOL:-stratum+tcp://stratum.minebtx.com:3333}"
DISK="${DISK:-20}"
PWR_INTERVAL="${PWR_INTERVAL:-5}"
LAUNCH_TIMEOUT="${LAUNCH_TIMEOUT:-1500}"
LABEL="${LABEL:-matador-mgpu}"
OUT="${OUT:-bench-results/vast-mgpu-$(date +%Y%m%d-%H%M%S).csv}"
DRY_RUN="${DRY_RUN:-0}"

log(){ printf '[mgpu %s] %s\n' "$(date +%T)" "$*" >&2; }
die(){ printf '[mgpu] ERROR: %s\n' "$*" >&2; exit 1; }

[ -f .env ] && { set -a; . ./.env; set +a; }
[ -n "${VAST_API_KEY:-}" ] || die "VAST_API_KEY not set (put it in .env)"
command -v vastai >/dev/null || die "vastai CLI not found (uv tool install vastai)"
PAYOUT="$(grep -oE 'btx1[a-z0-9]+' address.txt | head -1)"
[ -n "$PAYOUT" ] || die "no btx1... payout address in address.txt"
mkdir -p "$(dirname "$OUT")"
WORKER="$LABEL"

CREATED=""
cleanup(){
  [ -z "$CREATED" ] && return
  log "cleanup: destroying instance $CREATED"
  vastai destroy instance "$CREATED" -y >/dev/null 2>&1 && log "  destroyed $CREATED" \
    || log "  FAILED destroy $CREATED — CHECK 'vastai show instances-v1'"
}
trap cleanup EXIT INT TERM

# ---- onstart: runs on the box (POSIX sh; $VARS expand THERE via --env) ----
read -r -d '' ONSTART <<'ONSTART_EOF' || true
set -u
export DEBIAN_FRONTEND=noninteractive
echo "MGPU_BOOT $(date -u +%FT%TZ)"
apt-get update -qq >/dev/null 2>&1 || true
apt-get install -y -qq curl ca-certificates coreutils >/dev/null 2>&1 || true
retry(){ a=1; while [ "$a" -le 5 ]; do "$@" && return 0; echo "MGPU_RETRY $a: $*"; sleep $((a*8)); a=$((a+1)); done; return 1; }
install_main(){ curl -fsSL https://raw.githubusercontent.com/vanities/matador-miner/main/install.sh | PREFIX=/usr/local/bin bash; }
retry install_main || { echo "MGPU_FAIL install"; exit 0; }
matador-miner --version 2>/dev/null | sed 's/^/MGPU_VER /' | head -1 || true
NGPU=$(nvidia-smi -L 2>/dev/null | wc -l | tr -d ' ')
echo "MGPU_NGPU $NGPU"
[ "${NGPU:-0}" -ge 2 ] || { echo "MGPU_FAIL only ${NGPU:-0} gpu(s)"; exit 0; }
# AUTO fan-out: no --gpus -> supervisor forks one child per GPU, child API on 4060+i
matador-miner --mode pool --backend cuda --pool "$BPOOL" --worker "$BWORKER" \
  --payoutaddress "$BPAYOUT" --api --api-port 4060 >/var/log/matador.log 2>&1 &
SVPID=$!
echo "MGPU_WAIT apis (svpid=$SVPID)"
i=0; LAST=$((4060+NGPU-1))
t=1
while [ "$t" -le 60 ]; do
  up=0; p=4060
  while [ "$p" -le "$LAST" ]; do curl -sf "localhost:$p/summary" >/dev/null 2>&1 && up=$((up+1)); p=$((p+1)); done
  utils=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | paste -sd, -)
  sv=$(kill -0 "$SVPID" 2>/dev/null && echo up || echo DEAD)
  echo "MGPU_HB t=$((t*5))s apis_up=$up/$NGPU sv=$sv util=[$utils]"
  [ "$up" -ge "$NGPU" ] && break
  [ "$sv" = "DEAD" ] && { echo "MGPU_FAIL supervisor died early"; grep -aiE 'error|fatal|insufficient|no_kernel|cuda' /var/log/matador.log 2>/dev/null | tail -8 | sed 's/^/MGPU_ERR /' | cut -c1-150; exit 0; }
  t=$((t+1)); sleep 5
done
# fan-out evidence (short, de-wrapped lines)
grep -aE '\[multi-gpu\]' /var/log/matador.log 2>/dev/null | cut -c1-150 | sed 's/^/MGPU_MG /' | head -40
# warmup
sleep "${BWARMUP:-90}"
# t0 snapshot per child (cumulative batched_attempts) -> temp files (POSIX, no arrays)
p=4060
while [ "$p" -le "$LAST" ]; do
  curl -sf "localhost:$p/summary" 2>/dev/null | grep -oE '"batched_attempts":[0-9]+' | grep -oE '[0-9]+' | head -1 > "/tmp/a0_$p" || echo 0 > "/tmp/a0_$p"
  [ -s "/tmp/a0_$p" ] || echo 0 > "/tmp/a0_$p"
  p=$((p+1))
done
T0=$(date +%s)
ME=$(( T0 + ${BMEASURE:-60} ))
while [ "$(date +%s)" -lt "$ME" ]; do
  nvidia-smi --query-gpu=index,power.draw,utilization.gpu,temperature.gpu --format=csv,noheader,nounits 2>/dev/null \
    | while IFS= read -r row; do echo "MGPU_GPU $(echo "$row" | tr -d ' ')"; done
  sleep "${BPWR_INTERVAL:-5}"
done
T1=$(date +%s); DT=$((T1-T0)); [ "$DT" -lt 1 ] && DT=1
# t1 per child + nonce/s delta
p=4060
while [ "$p" -le "$LAST" ]; do
  s=$(curl -sf "localhost:$p/summary" 2>/dev/null)
  a1=$(echo "$s" | grep -oE '"batched_attempts":[0-9]+' | grep -oE '[0-9]+' | head -1); a1=${a1:-0}
  acc=$(echo "$s" | grep -oE '"accepted":[0-9]+' | grep -oE '[0-9]+' | head -1); acc=${acc:-0}
  rej=$(echo "$s" | grep -oE '"rejected":[0-9]+' | grep -oE '[0-9]+' | head -1); rej=${rej:-0}
  w=$(echo "$s"  | grep -oE '"worker":"[^"]*"' | head -1 | sed 's/.*:"//;s/"$//')
  be=$(echo "$s" | grep -oE '"backend":"[^"]*"' | head -1 | sed 's/.*:"//;s/"$//')
  st=$(echo "$s" | grep -oE '"mining_state":"[^"]*"' | head -1 | sed 's/.*:"//;s/"$//')
  a0=$(cat "/tmp/a0_$p" 2>/dev/null || echo 0)
  nps=$(awk -v a0="$a0" -v a1="$a1" -v dt="$DT" 'BEGIN{d=a1-a0; if(d<0)d=0; printf "%.0f", d/dt}')
  echo "MGPU_CHILD i=$((p-4060)) port=$p worker=${w:-?} backend=${be:-?} state=${st:-?} nonce_per_s=$nps acc=$acc rej=$rej"
  p=$((p+1))
done
echo "MGPU_DONE"
kill "$SVPID" 2>/dev/null || true
ONSTART_EOF

# ---- find cheapest viable multi-GPU offer ----
log "searching: num_gpus>=$NGPU, rel>$MIN_RELIABILITY, <\$$MAX_PRICE/hr, >=${MIN_CPU} vCPU${GPU_NAME:+, gpu=\"$GPU_NAME\"}"
QUERY="rentable=true num_gpus>=$NGPU reliability>$MIN_RELIABILITY dph_total<$MAX_PRICE"
[ -n "$GPU_NAME" ] && QUERY="$QUERY gpu_name=\"$GPU_NAME\""
read -r OID DPH CC NG CPU GNAME < <(
  vastai search offers "$QUERY" --order 'dph_total' --raw --limit 120 2>/dev/null \
  | NGPU="$NGPU" MIN_CPU="$MIN_CPU" python3 -c "
import sys,json,os
NGPU=int(os.environ['NGPU']); MINCPU=float(os.environ['MIN_CPU'])
try: d=json.load(sys.stdin)
except Exception: sys.exit()
MAIN={800,860,890,900,1200}   # Ampere/Ada/Hopper/Blackwell (compute_cap x100); main binary is CUDA13/sm_80+
for o in sorted(d,key=lambda x:x.get('dph_total') or 9e9):
    cc=int(o.get('compute_cap') or 0)
    if cc not in MAIN: continue
    if int(o.get('num_gpus') or 0) < NGPU: continue
    try: drv=float(o.get('cuda_max_good') or 0)
    except: drv=0
    if drv < 13.0: continue
    cpu=float(o.get('cpu_cores_effective') or 0)
    if cpu < MINCPU: continue
    print(o['id'], round(o.get('dph_total') or 0,3), cc, int(o.get('num_gpus') or 0), round(cpu,1), (o.get('gpu_name','?') or '?').replace(' ','_'))
    break
"
)
[ -n "${OID:-}" ] || die "no viable >=${NGPU}-GPU offer (<\$$MAX_PRICE, rel>$MIN_RELIABILITY, >=${MIN_CPU} vCPU, Ampere+ w/ CUDA13 driver). Loosen MAX_PRICE / MIN_CPU / NGPU."
GMODEL="$(echo "$GNAME" | tr '_' ' ')"
est_hr="$(python3 -c "print(round($DPH*(($WARMUP+$MEASURE+360)/3600),2))")"
log "offer $OID: ${NG}x $GMODEL  sm_$CC  \$$DPH/hr  cpu=${CPU}t  -> est ~\$$est_hr for this test"

if [ "$DRY_RUN" = "1" ]; then log "DRY_RUN=1 — nothing launched."; exit 0; fi

# ---- launch ----
out="$(vastai create instance "$OID" --image "$IMAGE" --disk "$DISK" --label "$LABEL" \
      --onstart-cmd "$ONSTART" \
      --env "-e BPOOL=$POOL -e BWORKER=$WORKER -e BPAYOUT=$PAYOUT -e BWARMUP=$WARMUP -e BMEASURE=$MEASURE -e BPWR_INTERVAL=$PWR_INTERVAL" \
      --raw 2>&1)"
CREATED="$(printf '%s' "$out" | python3 -c "import sys,json;print(json.load(sys.stdin).get('new_contract',''))" 2>/dev/null)"
[ -n "$CREATED" ] || die "create FAILED: $out"
log "launched ${NG}x $GMODEL -> instance $CREATED (worker=$WORKER, children $WORKER-gpu0..$((NG-1)))"

# ---- poll logs until MGPU_DONE / MGPU_FAIL ----
deadline=$(( $(date +%s) + LAUNCH_TIMEOUT ))
LOGS=""
while :; do
  LOGS="$(vastai logs "$CREATED" 2>/dev/null)"
  if printf '%s' "$LOGS" | grep -q 'MGPU_DONE'; then log "MGPU_DONE — parsing + destroying"; break; fi
  if printf '%s' "$LOGS" | grep -q 'MGPU_FAIL'; then
    log "MGPU_FAIL: $(printf '%s' "$LOGS" | grep 'MGPU_FAIL' | tail -1)"
    printf '%s' "$LOGS" | grep -E 'MGPU_(ERR|HB)' | tail -6 >&2
    break
  fi
  hb="$(printf '%s' "$LOGS" | grep 'MGPU_HB' | tail -1)"; [ -n "$hb" ] && log "  $hb"
  [ "$(date +%s)" -ge "$deadline" ] && { log "TIMEOUT ${LAUNCH_TIMEOUT}s"; break; }
  sleep 20
done

# ---- parse + report (raw sentinels saved FIRST so a parser bug never loses data) ----
RAW="${OUT%.csv}.raw.log"
printf '%s\n' "$LOGS" | grep -aE 'MGPU_' > "$RAW" 2>/dev/null || true
log "raw sentinels -> $RAW ($(wc -l < "$RAW" 2>/dev/null | tr -d ' ') lines)"
RAW="$RAW" GMODEL="$GMODEL" NG="$NG" DPH="$DPH" OUT="$OUT" python3 -c '
import os,re,collections
txt=open(os.environ["RAW"]).read()
gmodel=os.environ["GMODEL"]; ng=int(os.environ["NG"]); dph=os.environ["DPH"]; out=os.environ["OUT"]
def first(pat,d="?"):
    m=re.search(pat,txt); return m.group(1) if m else d
ver=first(r"MGPU_VER\s+(\S+)"); ngpu=first(r"MGPU_NGPU\s+(\d+)")
mg=[l.split("MGPU_MG",1)[1].strip() for l in txt.splitlines() if "MGPU_MG" in l]
gpu=collections.defaultdict(lambda:{"p":[],"u":[],"t":[]})
for m in re.findall(r"MGPU_GPU\s+([0-9.,]+)",txt):
    c=m.split(",")
    if len(c)>=4:
        try:
            i=int(c[0]); gpu[i]["p"].append(float(c[1])); gpu[i]["u"].append(float(c[2])); gpu[i]["t"].append(float(c[3]))
        except Exception: pass
def mean(x): return sum(x)/len(x) if x else 0.0
ch=re.findall(r"MGPU_CHILD i=(\d+) port=(\d+) worker=(\S+) backend=(\S+) state=(\S+) nonce_per_s=(\d+) acc=(\d+) rej=(\d+)",txt)
ch=sorted(ch,key=lambda r:int(r[0]))
print("")
print("=== matador-miner multi-GPU: %dx %s  (binary %s, detected %s GPUs) ===" % (ng,gmodel,ver,ngpu))
print("")
print("fan-out (supervisor):")
for l in mg: print("  "+l)
if not mg: print("  (none captured)")
print("")
print("per physical GPU (host nvidia-smi, measure-window avg):")
print("  %3s %8s %8s %7s" % ("gpu","util%","watts","temp"))
tot_w=0.0; lit=0
for idx in sorted(gpu):
    u=mean(gpu[idx]["u"]); p=mean(gpu[idx]["p"]); t=mean(gpu[idx]["t"]); tot_w+=p
    if u>5: lit+=1
    print("  %3d %8.0f %8.0f %7.0f" % (idx,u,p,t))
if not gpu: print("  (no samples)")
print("")
print("per child (matador API):")
print("  %2s %5s %-24s %7s %7s %9s %4s %4s" % ("i","port","worker","backend","state","nonce/s","acc","rej"))
agg=0; tacc=0; trej=0; rates=[]; states=[]
for i,port,w,be,st,nps,acc,rej in ch:
    nps=int(nps); acc=int(acc); rej=int(rej); agg+=nps; tacc+=acc; trej+=rej; rates.append(nps); states.append(st)
    print("  %2s %5s %-24s %7s %7s %9d %4d %4d" % (i,port,w,be,st,nps,acc,rej))
if not ch: print("  (no child lines)")
best=max(rates) if rates else 0
per=mean(rates); scale=(agg/best) if best>0 else 0.0; hpw=(agg/tot_w) if tot_w>0 else 0.0
all_mining=bool(states) and all(s=="mining" for s in states)
want=int(ngpu) if ngpu.isdigit() else 2
runs=(lit>=want) and (len(ch)>=want) and all_mining and bool(rates) and all(r>0 for r in rates) and agg>0
print("")
print("AGGREGATE: %d nonce/s across %d GPUs | ~%.0f/GPU | scaling ~%.2fx of best | %.0f W box | %.1f nonce/W" % (agg,len(ch),per,scale,tot_w,hpw))
print("GPUS LIT: %d/%s utilized (>5%%)   SHARES: accepted=%d rejected=%d" % (lit,ngpu,tacc,trej))
print("VERDICT: %s  (multi-GPU %s)" % (("PASS" if (runs and trej==0 and tacc>0) else "REVIEW"),("RUNS" if runs else "needs review")))
with open(out,"w") as f:
    f.write("gpu_idx,port,worker,backend,state,nonce_per_s,accepted,rejected\n")
    for i,port,w,be,st,nps,acc,rej in ch: f.write("%s,%s,%s,%s,%s,%s,%s,%s\n"%(i,port,w,be,st,nps,acc,rej))
    f.write("# aggregate_nonce_per_s=%d box_watts=%.0f gpus_lit=%d/%s accepted=%d rejected=%d model=%s ng=%d dph=%s binary=%s\n"%(agg,tot_w,lit,ngpu,tacc,trej,gmodel,ng,dph,ver))
print("")
print("CSV -> "+out+"   RAW -> "+os.environ["RAW"])
' || { log "parse failed; raw data preserved in $RAW:"; cat "$RAW" >&2; }

log "done."
