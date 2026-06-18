#!/usr/bin/env bash
# check-build-context.sh — guard against the "COPY <gitignored path>" build break.
#
# A Docker build context that ships in a fresh clone contains EXACTLY the
# git-tracked files. If a Dockerfile COPY/ADDs a path that is gitignored or
# untracked (e.g. `COPY private/<something>` or a gitignored dir), the
# build works on the author's machine but fails for anyone who clones the repo:
#   failed to compute cache key: "/private/...": not found
#
# This test parses every tracked Dockerfile, extracts each local COPY/ADD source,
# and asserts it is tracked by git (so it survives a clean clone). Pure static
# check: no Docker, no network, runs anywhere. Exit non-zero on any violation.
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

# All tracked Dockerfiles (named Dockerfile or *.Dockerfile / Dockerfile.*).
dockerfiles_tmp=$(mktemp "${TMPDIR:-/tmp}/btx-dockerfiles.XXXXXX") || exit 2
trap 'rm -f "$dockerfiles_tmp"' EXIT

git ls-files | grep -iE '(^|/)Dockerfile([.][^/]*)?$|[.]Dockerfile$' > "$dockerfiles_tmp" || true
if [ ! -s "$dockerfiles_tmp" ]; then
  note "[check-build-context] no Dockerfiles tracked — nothing to check"; exit 0
fi

while IFS= read -r df; do
  note "[check-build-context] $df"
  # Read COPY/ADD lines (case-insensitive). We only care about copies FROM the
  # build context: skip `--from=` (those copy from another stage/image) and skip
  # remote ADD sources (http/https/git URLs).
  while IFS= read -r line; do
    # Normalize leading whitespace; match COPY or ADD as the instruction.
    instr=$(printf '%s' "$line" | awk '{print toupper($1)}')
    [ "$instr" = "COPY" ] || [ "$instr" = "ADD" ] || continue
    printf '%s' "$line" | grep -qiE -- '--from=' && continue   # from a build stage, not the context

    # Drop the instruction word and any --flags; the remaining tokens are
    # `src... dest`. The last token is the destination → everything before it is
    # a context source path to validate.
    rest=$(printf '%s' "$line" | sed -E 's/^[[:space:]]*[A-Za-z]+[[:space:]]+//')
    # strip --chown=.. --chmod=.. etc.
    rest=$(printf '%s' "$rest" | sed -E 's/(^|[[:space:]])--[A-Za-z-]+=[^[:space:]]+//g')
    # collapse to tokens
    read -ra toks <<< "$rest"
    [ "${#toks[@]}" -ge 2 ] || continue
    n=${#toks[@]}
    for ((i=0; i<n-1; i++)); do
      src="${toks[$i]}"
      # skip JSON-array form leftovers, remote URLs, and absolute paths
      case "$src" in
        \[*|*://*|/*) continue ;;
      esac
      src="${src%/}"   # normalize trailing slash for ls-files
      if [ -z "$(git ls-files -- "$src" "$src/"* 2>/dev/null | head -1)" ]; then
        note "  ✗ COPY/ADD source NOT tracked by git: '$src'"
        note "    (a fresh clone won't have it → docker build will fail with 'not found')"
        note "    fix: move it to a tracked path, or it must not be gitignored."
        fail=1
      else
        note "  ✓ $src"
      fi
    done
  done < "$df"
done < "$dockerfiles_tmp"

if [ "$fail" -ne 0 ]; then
  note ""
  note "[check-build-context] FAIL: a Dockerfile COPY/ADDs an untracked path."
  exit 1
fi
elapsed=$(( $(now_ms) - start_ms ))
note "[check-build-context] OK: all Dockerfile COPY/ADD sources are tracked in ${elapsed}ms."
