#!/usr/bin/env bash
# install.sh - download, verify (sha256), and install the latest matador-miner.
#
#   curl -fsSL https://raw.githubusercontent.com/vanities/matador-miner/main/install.sh | bash
#
# Env options:
#   VERSION=v0.1.0          install a specific tag (default: latest release)
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

if [ -n "${VERSION:-}" ]; then
  api="https://api.github.com/repos/$REPO/releases/tags/$VERSION"
else
  api="https://api.github.com/repos/$REPO/releases/latest"
fi

log "resolving release: $api"
json="$(curl -fsSL "$api")" || die "cannot reach the GitHub API (is a release published yet?)"
url="$(printf '%s' "$json" | grep -oE '"browser_download_url": *"[^"]+linux-x86_64"' | cut -d'"' -f4 | head -1)"
[ -n "$url" ] || die "no linux-x86_64 binary asset found in that release"
asset="$(basename "$url")"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
log "downloading $asset"
curl -fsSL "$url"        -o "$tmp/$asset"
curl -fsSL "$url.sha256" -o "$tmp/$asset.sha256" || die "release is missing the .sha256 checksum asset"

log "verifying checksum"
( cd "$tmp" && $SHACHK -c "$asset.sha256" >/dev/null ) || die "CHECKSUM MISMATCH - refusing to install"
log "checksum OK"
chmod +x "$tmp/$asset"

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
log "next: matador-miner --help   (needs a synced btxd v0.32.11+ with RPC)"
