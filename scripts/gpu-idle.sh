#!/usr/bin/env bash
# gpu-idle.sh - reference idle-gate for matador's --should-mine-command.
#
#   matador-miner ... --should-mine-command "/path/gpu-idle.sh 5"
#
# exit 0 = MINE, non-zero = YIELD (matador pauses + frees the GPU). Prints a one-line
# reason on stdout that matador surfaces as /summary "gate_reason".
#
# "Idle" = no OTHER GPU compute process is running. We deliberately key off the PRESENCE
# of foreign compute apps, NOT raw GPU utilization: while matador is mining the GPU is at
# ~99%, so a util-threshold gate would see "busy", yield, then thrash. Excluding our own
# miner (SELF match) and watching for anyone *else* on the GPU avoids that feedback loop
# and directly answers "does something else need this GPU?".
#
# Hysteresis lives here: only return MINE after the GPU has been free of foreign apps for
# <idle_min> minutes (avoids flapping the GPU up to full power on brief gaps between jobs).
#
# Usage: gpu-idle.sh <idle_min> [gpu_index] [self_match]
#   idle_min    minutes the GPU must be free before we (re)start mining   (default 5)
#   gpu_index   which GPU to watch                                        (default 0)
#   self_match  substring identifying OUR miner in process names          (default matador)
#
# NOTE: nvidia-smi --query-compute-apps lists CUDA/compute processes. Desktop GAMES use a
# graphics context and may not appear here - to yield to gaming/desktop use, gate on a
# session/activity check instead (point --should-mine-command at your own script).
set -u
IDLE_MIN="${1:-5}"
GPU="${2:-0}"
SELF="${3:-matador}"
STATE="/tmp/matador-gpu-idle.${GPU}.since"

apps="$(nvidia-smi -i "$GPU" --query-compute-apps=pid,process_name --format=csv,noheader 2>/dev/null)"
if [ $? -ne 0 ]; then
  echo "nvidia-smi unavailable; yield"
  exit 1
fi

# Count compute apps that are NOT our own miner.
foreign="$(printf '%s\n' "$apps" | grep -vi "$SELF" | grep -c '[^[:space:]]')"
now="$(date +%s)"

if [ "${foreign:-0}" -gt 0 ]; then
  rm -f "$STATE"
  echo "yield: ${foreign} other GPU compute app(s) on gpu${GPU}"
  exit 1
fi

# GPU is free of foreign apps - track how long, apply the idle_min hysteresis.
since="$(cat "$STATE" 2>/dev/null || true)"
if [ -z "${since:-}" ]; then
  echo "$now" > "$STATE"
  since="$now"
fi
idle_s=$(( now - since ))
need=$(( IDLE_MIN * 60 ))
if [ "$idle_s" -ge "$need" ]; then
  echo "mine: gpu${GPU} free of other apps for ${idle_s}s"
  exit 0
fi
echo "wait: gpu${GPU} free ${idle_s}s (< ${need}s)"
exit 1
