#!/usr/bin/env bash
# install.sh - download, verify (sha256), smoke-test, and install matador-miner.
#
#   curl -fsSL https://raw.githubusercontent.com/vanities/matador-miner/main/install.sh | bash
#
# Env options:
#   VERSION=v0.3.0          install a specific tag (default: newest release incl. prereleases)
#   PREFIX=$HOME/.local/bin install dir (default: /usr/local/bin via sudo, else ~/.local/bin)
#   REPO=owner/name         override the source repo (default: vanities/matador-miner)
set -euo pipefail

REPO="${REPO:-vanities/matador-miner}"
log(){ printf '[install] %s\n' "$*" >&2; }
die(){ printf '[install] ERROR: %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null || die "curl is required"
if   command -v sha256sum >/dev/null; then SHACHK="sha256sum"
elif command -v shasum    >/dev/null; then SHACHK="shasum -a 256"
else die "need sha256sum or shasum to verify the download"; fi

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) asset_pattern='linux-x86_64' ;;
  Darwin-arm64) asset_pattern='macos-arm64' ;;
  *) die "unsupported platform $(uname -s)-$(uname -m); expected Linux x86_64 or macOS arm64" ;;
esac

# GPU-arch routing (Linux/NVIDIA): the main CUDA-13 build needs compute capability >= 8.0
# (Ampere+). If the highest installed GPU is older (Pascal/Volta/Turing, < 8.0), route to the
# experimental -legacy asset when the release ships one. LEGACY=1 forces it; LEGACY=0 opts out.
want_legacy="${LEGACY:-}"
if [ -z "$want_legacy" ] && [ "$asset_pattern" = linux-x86_64 ] && command -v nvidia-smi >/dev/null 2>&1; then
  maxcc="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | tr -d ' ' | sort -g | tail -1)"
  if [ -n "$maxcc" ] && awk "BEGIN{exit !($maxcc < 8.0)}" 2>/dev/null; then
    want_legacy=1
    log "GPU compute capability $maxcc is < 8.0 (Pascal/Volta/Turing); the main build can't run on it"
  fi
fi
[ "$want_legacy" = 0 ] && want_legacy=""

if [ -n "${VERSION:-}" ]; then
  api="https://api.github.com/repos/$REPO/releases/tags/$VERSION"
else
  # /releases is newest-first and includes prereleases. /releases/latest skips prereleases.
  api="https://api.github.com/repos/$REPO/releases"
fi

log "resolving release: $api"
json="$(curl -fsSL "$api")" || die "cannot reach the GitHub API (is a release published yet?)"
if [ -n "$want_legacy" ]; then
  # `|| true`: no -legacy match must fall through to the helpful die, not silently exit via set -e/pipefail
  url="$(printf '%s' "$json" | grep -oE '"browser_download_url": *"[^"]+-legacy-'"$asset_pattern"'"' | cut -d'"' -f4 | head -1 || true)"
  if [ -n "$url" ]; then
    log "routing to the EXPERIMENTAL -legacy build for your GPU (Pascal/Volta/Turing; unvalidated - please report results)"
  else
    die "your GPU needs the -legacy build, but this release has none. Grab the experimental legacy asset from https://github.com/$REPO/releases and run it with --no-auto-update."
  fi
else
  # main asset matches the platform but NOT the -legacy- variant published beside it
  url="$(printf '%s' "$json" | grep -oE '"browser_download_url": *"[^"]+'"$asset_pattern"'"' | grep -v -- '-legacy-' | cut -d'"' -f4 | head -1 || true)"
fi
[ -n "$url" ] || die "no $asset_pattern binary asset found in that release"
asset="$(basename "$url")"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
log "downloading $asset"
curl -fsSL "$url"        -o "$tmp/$asset"
curl -fsSL "$url.sha256" -o "$tmp/$asset.sha256" || die "release is missing the .sha256 checksum asset"

log "verifying checksum"
( cd "$tmp" && $SHACHK -c "$asset.sha256" >/dev/null ) || die "CHECKSUM MISMATCH - refusing to install"
log "checksum OK"
chmod +x "$tmp/$asset"

log "smoke-testing binary"
"$tmp/$asset" --help >/dev/null || die "downloaded binary failed --help smoke test"
if [ "$asset_pattern" = linux-x86_64 ]; then
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=name,driver_version --format=csv,noheader | sed 's/^/[install] nvidia: /' >&2 || true
  else
    log "nvidia-smi not found; skipping NVIDIA driver visibility check"
  fi
fi

# Pick an install dir: explicit PREFIX, else /usr/local/bin (sudo), else ~/.local/bin.
if [ -n "${PREFIX:-}" ]; then
  mkdir -p "$PREFIX"; mv "$tmp/$asset" "$PREFIX/matador-miner"; dst="$PREFIX"
elif [ -w /usr/local/bin ]; then
  mv "$tmp/$asset" /usr/local/bin/matador-miner; dst="/usr/local/bin"
elif command -v sudo >/dev/null; then
  log "installing to /usr/local/bin (sudo)"
  sudo mv "$tmp/$asset" /usr/local/bin/matador-miner; dst="/usr/local/bin"
else
  mkdir -p "$HOME/.local/bin"; mv "$tmp/$asset" "$HOME/.local/bin/matador-miner"; dst="$HOME/.local/bin"
fi

log "installed -> $dst/matador-miner"
case ":$PATH:" in *":$dst:"*) ;; *) log "NOTE: add $dst to your PATH";; esac
log "next: matador-miner --help"
log "pool example: matador-miner --mode pool --pool stratum+tcp://stratum.minebtx.com:3333 --pool stratum+tcp://stratum.bitminerpool.xyz:3333 --worker rig1 --payoutaddress btx1zcf4z36asua8ylchysphgwfgyfr8267vvznth826epden7lar4fnqvy9gzv --api --api-port 4060"
