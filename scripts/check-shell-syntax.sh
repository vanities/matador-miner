#!/usr/bin/env bash
# check-shell-syntax.sh — fast syntax check for shell entrypoints/helpers.
#
# This is intentionally Docker/GPU/network-free so `make check` can run on a
# laptop and in CI. It validates shell syntax through the public interface we
# actually ship: repo scripts and container entrypoints. Include untracked,
# non-ignored files too so new scripts are checked before their first commit.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

fail=0
note() { printf '%s\n' "$*" >&2; }
now_ms() {
  if command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
  else
    date +%s000
  fi
}

start_ms=$(now_ms)
note "[check-shell-syntax] scanning shell files"

files_tmp=$(mktemp "${TMPDIR:-/tmp}/btx-shell-files.XXXXXX") || exit 2
trap 'rm -f "$files_tmp"' EXIT

git ls-files --cached --others --exclude-standard | while IFS= read -r f; do
  case "$f" in
    *.sh|install.sh|node/entrypoint.sh)
      printf '%s\n' "$f"
      ;;
  esac
done > "$files_tmp"

if [ ! -s "$files_tmp" ]; then
  note "[check-shell-syntax] no shell files — nothing to check"
  exit 0
fi

while IFS= read -r f; do
  if bash -n "$f"; then
    note "  ✓ $f"
  else
    note "  ✗ shell syntax failed: $f"
    fail=1
  fi
done < "$files_tmp"

elapsed=$(( $(now_ms) - start_ms ))
if [ "$fail" -ne 0 ]; then
  note "[check-shell-syntax] FAIL in ${elapsed}ms"
  exit 1
fi
note "[check-shell-syntax] OK in ${elapsed}ms"
