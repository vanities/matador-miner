#!/usr/bin/env bash
# MATADOR pool-mode entrypoint (our BTX MatMul miner, fork of thekillsquad007/
# btx-nvidia-miner). Builds the CLI from container env so the payout address + tuning
# are explicit and the image stays stateless. Only runs for the `matador` compose
# service (`make matador`). Solo/official-pool modes are unaffected.
#
# MATADOR is a single integrated binary: stratum client + CUDA solver. It saturates
# the 5090 (~86-95%) and lands valid v3 shares, unlike the official btx-gbt-solve which
# regressed to ~3% util after v3. We build it FROM SOURCE at a pinned, audited commit
# (Dockerfile.matador) and apply our own kernel optimizations as patches.
set -euo pipefail

log() { echo -e "\033[1;36m[matador]\033[0m $*"; }

ADDRESS="${BTX_PAYOUT_ADDRESS:-}"
if [ -z "$ADDRESS" ]; then
  echo "[matador] ERROR: BTX_PAYOUT_ADDRESS is unset. Pool payouts would be lost." >&2
  exit 1
fi
case "$ADDRESS" in
  btx1z*) : ;;
  *) log "WARNING: address '$ADDRESS' is not btx1z... — double-check it's your BTX payout address." ;;
esac

POOL_HOST="${BTX_POOL_HOST:-stratum.minebtx.com}"
POOL_PORT="${BTX_POOL_PORT:-3333}"
WORKER="${BTX_POOL_WORKER:-$(hostname -s 2>/dev/null || echo rig)}"
# Built-in dev fee to the upstream author (1 mining slice in 100). Honest at ~1%; set
# BTX_DEV_FEE=0 to keep all shares. Default 1 as courtesy to the dev who filled the gap.
DEV_FEE="${BTX_DEV_FEE:-1}"
DEVICES="${BTX_DEVICES:-all}"

log "pool=${POOL_HOST}:${POOL_PORT}  worker=${WORKER}  devices=${DEVICES}  dev_fee=${DEV_FEE}%"
log "payout → ${ADDRESS}"
log "NOTE: MATADOR (fork of thekillsquad007/btx-nvidia-miner), integrated stratum+CUDA, v3-aware."

# --dev-fee accepts 0-5; the miner clamps. Extra args ("$@") pass through for ad-hoc tuning.
exec btx-miner \
  --pool "stratum+tcp://${POOL_HOST}:${POOL_PORT}" \
  --user "${ADDRESS}.${WORKER}" \
  --pass x \
  --devices "${DEVICES}" \
  --dev-fee "${DEV_FEE}" \
  "$@"
