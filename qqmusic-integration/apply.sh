#!/usr/bin/env bash
#
# Integrate the QQ Music online source into a kmgccc_player checkout.
#
# Usage:
#   ./apply.sh [--repo DIR] [--baseline DIR] [--reset] [--dry-run] [--verify]
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
# The target does not have to be a git repository. Only --reset and the 3-way
# fallback need one; without it a failing patch falls back to --reject, which
# keeps the hunks that did apply and leaves the rest in a .rej file.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${HERE}/.."
BASELINE=""
DRY_RUN=0
DO_RESET=0
DO_VERIFY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)     REPO="$2"; shift 2 ;;
    --baseline) BASELINE="$2"; shift 2 ;;
    --reset)    DO_RESET=1; shift ;;
    --verify)   DO_VERIFY=1; shift ;;
    --dry-run)  DRY_RUN=1; shift ;;
    -h|--help)  sed -n '3,25p' "$0"; exit 0 ;;
    *) echo "error: unknown option $1" >&2; exit 2 ;;
  esac
done

REPO="$(cd "$REPO" && pwd)"
[[ -d "$REPO/kmgccc_player" ]] || { echo "error: not a kmgccc_player checkout: $REPO" >&2; exit 2; }

# A checkout of pristine upstream enables --reset and the 3-way fallback when
# the target itself is not a git repository. Defaults to the sibling upstream/
# that test-cycle.sh keeps around.
if [[ -z "$BASELINE" && -d "${HERE}/../upstream/kmgccc_player" ]]; then
  BASELINE="$(cd "${HERE}/../upstream" && pwd)"
fi

is_git_repo() { git -C "$1" rev-parse --git-dir >/dev/null 2>&1; }

applied=0; skipped=0; conflicted=0; reverted=0
conflict_files=()

echo "== QQ Music integration =="
echo "repo:     $REPO"
if is_git_repo "$REPO"; then
  echo "target:   git repository (3-way fallback available)"
else
  echo "target:   plain directory (falls back to --reject)"
fi
[[ -n "$BASELINE" ]] && echo "baseline: $BASELINE"
[[ $DRY_RUN -eq 1 ]] && echo "mode:     dry run"
echo

# --- reset -------------------------------------------------------------------
# Restore every file this toolkit touches from the pristine baseline and drop
# what a previous run added, so the result never depends on what was there
# before. Without it a second `apply.sh` on an already-patched tree reports
# "exists and differs" for modules and fails every patch.
if (( DO_RESET == 1 )); then
  echo "-- 0/3 reset from baseline --"
  if [[ -z "$BASELINE" || ! -d "$BASELINE/kmgccc_player" ]]; then
    echo "error: --reset needs a pristine upstream checkout; pass --baseline DIR" >&2
    exit 2
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "  (dry run: would restore patch targets and remove added files)"
  else
    while IFS= read -r patch; do
      target="$(sed -n 's|^+++ b/||p' "$patch" | head -1)"
      [[ -n "$target" ]] || continue
      if [[ -f "$BASELINE/$target" ]]; then
        mkdir -p "$(dirname "$REPO/$target")"
        cp "$BASELINE/$target" "$REPO/$target"
        reverted=$((reverted + 1))
      fi
      rm -f "$REPO/$target.rej" "$REPO/$target.orig"
    done < <(find "$HERE/patches" -name '*.patch' | sort)
    while IFS= read -r rel; do
      rm -f "$REPO/$rel"
    done < <(cd "$HERE/modules" && find . -type f | sed 's|^\./||' | sort)
    echo "  restored $reverted upstream file(s), cleared previously added file(s)"
  fi
  echo
fi

# --- modules -----------------------------------------------------------------
echo "-- 1/3 new files (modules/) --"
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

# --- patches -----------------------------------------------------------------
echo
echo "-- 2/3 patches to upstream files (patches/) --"
while IFS= read -r patch; do
  name="$(basename "$patch" .patch)"
  # The patch carries the real path; read it from the diff header rather than
  # reconstructing it from the filename, which cannot distinguish an original
  # underscore (kmgccc_player) from a substituted slash.
  target="$(sed -n 's|^+++ b/||p' "$patch" | head -1)"
  [[ -n "$target" ]] || target="$name"

  if [[ $DRY_RUN -eq 1 ]]; then
    if git -C "$REPO" apply --check "$patch" >/dev/null 2>&1; then
      printf '  + %s\n' "$target"; applied=$((applied + 1))
    else
      printf '  ! %s — would need manual merge\n' "$target"
      conflicted=$((conflicted + 1)); conflict_files+=("$name")
    fi
    continue
  fi

  # --3way needs a repository to read blob ids from; --reject does not.
  # Try the strongest strategy this target supports, then weaken.
  if git -C "$REPO" apply "$patch" >/dev/null 2>&1; then
    printf '  + %s\n' "$target"; applied=$((applied + 1))
  elif is_git_repo "$REPO" && git -C "$REPO" apply --3way --reject "$patch" >/dev/null 2>&1; then
    printf '  ~ %s — merged 3-way, review *.rej\n' "$target"
    applied=$((applied + 1)); conflict_files+=("$name (.rej)"); conflicted=$((conflicted + 1))
  elif git -C "$REPO" apply --reject "$patch" >/dev/null 2>&1; then
    printf '  ~ %s — applied with rejects, review *.rej\n' "$target"
    applied=$((applied + 1)); conflict_files+=("$name (.rej)"); conflicted=$((conflicted + 1))
  elif git -C "$REPO" apply --check --reverse "$patch" >/dev/null 2>&1; then
    # The patch is already in the tree. Saying "FAILED, upstream changed this
    # file" here would send the reader hunting for an upstream conflict that
    # does not exist — the usual cause is simply a second run against a tree
    # that was already patched.
    printf '  = %s (already applied)\n' "$target"
    skipped=$((skipped + 1))
  else
    printf '  ! %s — FAILED, merge by hand using patches/%s.patch\n' "$target" "$name"
    conflict_files+=("$name"); conflicted=$((conflicted + 1))
  fi
done < <(find "$HERE/patches" -name '*.patch' | sort)

# --- verify ------------------------------------------------------------------
# "It applied" is not the same as "it produced the intended file". Compare the
# result against modules/ byte-for-byte, and refuse to call a tree healthy
# while it still carries conflict markers or unresolved rejects.
if (( DO_VERIFY == 1 && DRY_RUN == 0 )); then
  echo
  echo "-- 3/3 content check --"
  bad=0
  while IFS= read -r rel; do
    if ! cmp -s "$HERE/modules/${rel}" "$REPO/${rel}"; then
      printf '  ! %s does not match modules/\n' "$rel"; bad=$((bad + 1))
    fi
  done < <(cd "$HERE/modules" && find . -type f | sed 's|^\./||' | sort)
  while IFS= read -r patch; do
    target="$(sed -n 's|^+++ b/||p' "$patch" | head -1)"
    [[ -n "$target" && -f "$REPO/$target" ]] || continue
    if grep -qE '^(<<<<<<<|>>>>>>>)' "$REPO/$target" 2>/dev/null; then
      printf '  ! %s still has conflict markers\n' "$target"; bad=$((bad + 1))
    fi
    if [[ -f "$REPO/$target.rej" ]]; then
      printf '  ! %s has an unresolved .rej\n' "$target"; bad=$((bad + 1))
    fi
  done < <(find "$HERE/patches" -name '*.patch' | sort)
  if (( bad == 0 )); then
    echo "  all added files match, no conflict markers, no unresolved rejects"
  else
    echo "  $bad problem(s) above"
  fi
else
  echo
  echo "-- 3/3 content check (skipped; pass --verify) --"
fi

echo
echo "== summary: $applied applied, $skipped existing, $conflicted to review =="
if (( conflicted > 0 )); then
  echo
  echo "Files needing attention:"
  for f in "${conflict_files[@]}"; do echo "  - $f"; done
  echo
  echo "These patches did not apply cleanly, which usually means upstream"
  echo "changed that file. Port the intent by hand: read"
  echo "patches/<name>.patch, apply the change to the new code, then re-run."
  echo "If the tree was simply already patched, re-run with --reset instead."
fi

if (( conflicted == 0 && DRY_RUN == 0 )); then
  cat <<'NEXT'

Next steps:
  ./scripts/bootstrap.sh --component qqmusic-helper   # build the helper
  ./scripts/build_and_run.sh                          # build the app

See README.md for the verification checklist.
NEXT
fi
