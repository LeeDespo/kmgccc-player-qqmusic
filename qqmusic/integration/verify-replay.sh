#!/usr/bin/env bash
# Reconstruct the patch against the exact, clean BASE; do not just diff metadata.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BASE="$(head -n 1 "$HERE/BASE" | tr -d '\r')"
if ! git -C "$ROOT" cat-file -e "${BASE}^{commit}" 2>/dev/null; then
  echo "error: replay BASE commit not found: $BASE (fetch full history)" >&2
  exit 1
fi
TMP="$(mktemp -d "${TMPDIR:-/tmp}/qqmusic-replay.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
UPSTREAM="$TMP/upstream"
REPLAY="$TMP/replay"
mkdir -p "$UPSTREAM" "$REPLAY"
echo "== clean BASE replay =="
echo "base: $BASE"
git -C "$ROOT" archive "$BASE" | tar -xf - -C "$UPSTREAM"
tar -cf - -C "$UPSTREAM" . | tar -xf - -C "$REPLAY"
"$HERE/apply.sh" --repo "$REPLAY" --baseline "$UPSTREAM" --verify
failures=0
modules=0
patches=0
removals=0
# New files must match the live tree byte-for-byte, including execute bits.
while IFS= read -r -d '' src; do
  rel="${src#"$HERE/modules/"}"
  dst="$REPLAY/$rel"
  production="$ROOT/$rel"
  if [[ ! -f "$dst" || ! -f "$production" ]] ||
     ! cmp -s "$dst" "$production" ||
     [[ -x "$dst" && ! -x "$production" ]] ||
     [[ ! -x "$dst" && -x "$production" ]]; then
    echo "FAIL: module mismatch: $rel" >&2
    failures=$((failures + 1))
  fi
  modules=$((modules + 1))
done < <(find "$HERE/modules" -type f -print0)
# A patch can apply cleanly but still reproduce an outdated target file.
while IFS= read -r -d '' patch; do
  rel="$(sed -n 's|^+++ b/||p' "$patch" | head -1)"
  if [[ -z "$rel" || ! -f "$REPLAY/$rel" || ! -f "$ROOT/$rel" ]] ||
     ! cmp -s "$REPLAY/$rel" "$ROOT/$rel"; then
    echo "FAIL: patch mismatch: $patch ($rel)" >&2
    failures=$((failures + 1))
  fi
  patches=$((patches + 1))
done < <(find "$HERE/patches" -type f -name '*.patch' -print0)
while IFS= read -r rel || [[ -n "$rel" ]]; do
  [[ -z "$rel" || "$rel" == \#* ]] && continue
  if [[ -e "$REPLAY/$rel" ]]; then
    echo "FAIL: removed path remains: $rel" >&2
    failures=$((failures + 1))
  fi
  removals=$((removals + 1))
done < "$HERE/removals.txt"
echo "replayed and compared: $modules modules, $patches patches, $removals removals"
if (( failures > 0 )); then
  echo "FAIL: $failures replay mismatch(es)" >&2
  exit 1
fi
echo "PASS: clean BASE replay matches the production tree"
