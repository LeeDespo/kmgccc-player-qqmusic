#!/usr/bin/env bash
#
# Integrate the QQ Music online source into a kmgccc_player checkout.
#
# Usage:
#   ./apply.sh [--repo /path/to/kmgccc_player] [--dry-run]
#
# Two kinds of change are applied, and they behave differently:
#
#   modules/  New files that upstream does not have. Copied verbatim; they
#             cannot conflict, so they always apply.
#
#   patches/  Modifications to files upstream owns. These are plain diffs, so
#             they apply cleanly only when the surrounding code still matches.
#             When upstream changes those files the patch will fail — that is
#             expected, not a bug. Each failure is reported with the file and
#             the patch to consult, and the run continues so one conflict does
#             not hide the rest.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${HERE}/.."
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '3,22p' "$0"; exit 0 ;;
    *) echo "error: unknown option $1" >&2; exit 2 ;;
  esac
done

REPO="$(cd "$REPO" && pwd)"
[[ -d "$REPO/kmgccc_player" ]] || { echo "error: not a kmgccc_player checkout: $REPO" >&2; exit 2; }

applied=0; skipped=0; conflicted=0
conflict_files=()

echo "== QQ Music integration =="
echo "repo: $REPO"
[[ $DRY_RUN -eq 1 ]] && echo "mode: dry run"
echo

echo "-- 1/2 new files (modules/) --"
while IFS= read -r rel; do
  src="${HERE}/modules/${rel}"
  dst="${REPO}/${rel}"
  if [[ -e "$dst" ]]; then
    # Never overwrite silently: a newer version may already be present.
    if cmp -s "$src" "$dst"; then
      printf '  = %s (already identical)\n' "$rel"
    else
      printf '  ! %s exists and differs — left untouched\n' "$rel"
      conflict_files+=("$rel (module differs)")
      conflicted=$((conflicted + 1))
    fi
    skipped=$((skipped + 1))
    continue
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '  + %s\n' "$rel"
  else
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    printf '  + %s\n' "$rel"
  fi
  applied=$((applied + 1))
done < <(cd "$HERE/modules" && find . -type f | sed 's|^\./||' | sort)

echo
echo "-- 2/2 patches to upstream files (patches/) --"
while IFS= read -r patch; do
  name="$(basename "$patch" .patch)"
  # The patch carries the real path; read it from the diff header rather than
  # reconstructing it from the filename, which cannot distinguish an original
  # underscore (kmgccc_player) from a substituted slash.
  target="$(sed -n 's|^+++ b/||p' "$patch" | head -1)"
  [[ -n "$target" ]] || target="$name"
  if [[ $DRY_RUN -eq 1 ]]; then
    if git -C "$REPO" apply --check --3way "$patch" >/dev/null 2>&1; then
      printf '  + %s\n' "$target"; applied=$((applied + 1))
    else
      printf '  ! %s — would need manual merge\n' "$target"
      conflicted=$((conflicted + 1)); conflict_files+=("$name")
    fi
    continue
  fi
  if git -C "$REPO" apply --3way "$patch" >/dev/null 2>&1; then
    printf '  + %s\n' "$target"; applied=$((applied + 1))
  elif git -C "$REPO" apply --3way --reject "$patch" >/dev/null 2>&1; then
    printf '  ~ %s — applied with rejects, review *.rej\n' "$target"
    applied=$((applied + 1)); conflict_files+=("$name (.rej)")
    conflicted=$((conflicted + 1))
  else
    printf '  ! %s — FAILED, merge by hand using patches/%s.patch\n' "$target" "$name"
    conflicted=$((conflicted + 1)); conflict_files+=("$name")
  fi
done < <(find "$HERE/patches" -name '*.patch' | sort)

echo
echo "== summary: $applied applied, $skipped existing, $conflicted to review =="
if (( conflicted > 0 )); then
  echo
  echo "Files needing attention:"
  for f in "${conflict_files[@]}"; do echo "  - $f"; done
  echo
  echo "A failed patch means upstream changed that file. Apply the intent by hand:"
  echo "read patches/<name>.patch, port the change, then re-run this script."
fi

cat <<'NEXT'

Next steps:
  ./scripts/bootstrap.sh --component qqmusic-helper   # build the helper
  ./scripts/build_and_run.sh                          # build the app

See README.md for the verification checklist.
NEXT
