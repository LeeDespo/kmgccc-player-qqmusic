#!/usr/bin/env bash
#
# Regenerate modules/ and patches/ from the development tree.
#
# Run this after every change you make to the QQ Music feature, so the toolkit
# and the working tree never drift apart. The toolkit is only trustworthy if
# this is the last thing you do before committing.
#
# Usage:
#   ./sync.sh [--base <commit>] [--from <repo>] [--check]
#
#   --base    Upstream commit the toolkit was cut against (default: recorded
#             in BASE, or the merge-base with origin/main).
#   --from    Development checkout to read from (default: this repository).
#   --check   Report what would change without writing anything. Use this in a
#             pre-commit habit: it exits non-zero when the toolkit is stale.
#
# Files are read from the working tree, not from HEAD, so uncommitted edits are
# captured too. What counts as changed is derived from `git diff <base>`.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FROM="${HERE}/.."
BASE=""
CHECK=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)  BASE="$2"; shift 2 ;;
    --from)  FROM="$2"; shift 2 ;;
    --check) CHECK=1; shift ;;
    -h|--help) sed -n '3,20p' "$0"; exit 0 ;;
    *) echo "error: unknown option $1" >&2; exit 2 ;;
  esac
done

FROM="$(cd "$FROM" && pwd)"
BASE_FILE="${HERE}/BASE"

if [[ -z "$BASE" ]]; then
  if [[ -f "$BASE_FILE" ]]; then
    BASE="$(head -1 "$BASE_FILE" | awk '{print $1}')"
  else
    BASE="$(git -C "$FROM" merge-base HEAD origin/main 2>/dev/null || true)"
  fi
fi
[[ -n "$BASE" ]] || { echo "error: cannot determine base commit; pass --base" >&2; exit 2; }
git -C "$FROM" cat-file -e "${BASE}^{commit}" 2>/dev/null \
  || { echo "error: base commit not found in $FROM: $BASE" >&2; exit 2; }

# Roots that belong to the shipped feature. Everything the toolkit carries must
# live under one of these; anything else is a local file that only happens to be
# untracked (a plan document, a scratch note) and must not be shipped. Without
# this the untracked-file sweep below copied such a file into `modules/`, which
# then planted it at the root of the target checkout.
#
# The toolkit's own directories are excluded by not appearing here at all.
#
# `kmgccc_playerTests/` is included on purpose: the tests that pin the online
# source's behaviour (shuffle order, sustained queue feeding) are part of the
# feature, not scratch work. They caught a regression that reading the code did
# not, so they have to travel with it.
is_shippable_path() {
  case "$1" in
    kmgccc_player/*|kmgccc_playerTests/*|Tools/QQMusicHelper/*|scripts/components/qqmusic-helper.sh|.gitignore) return 0 ;;
    # The app's sources live in file-system-synchronized folders, so they need
    # no project entries — but the TEST target is an explicit file list. Without
    # this file the package would copy the test files into a tree that never
    # compiles them: `xcodebuild test` prints TEST SUCCEEDED while skipping every
    # one, which is the exact silent failure described in AGENTS.md.
    kmgccc_player.xcodeproj/project.pbxproj) return 0 ;;
    *) return 1 ;;
  esac
}

echo "== sync toolkit =="
echo "from: $FROM"
echo "base: $BASE ($(git -C "$FROM" log -1 --format=%s "$BASE" | cut -c1-60))"
[[ $CHECK -eq 1 ]] && echo "mode: check only"
echo

# Files added by the feature go into modules/. Everything else that differs
# goes into patches/. A file the base already has but the tree deleted is an
# error: this toolkit cannot express deletions, so it must be resolved by hand.
added=(); modified=(); deleted=()
while IFS=$'\t' read -r st path; do
  is_shippable_path "$path" || continue
  case "$st" in
    A) added+=("$path") ;;
    M) modified+=("$path") ;;
    D) deleted+=("$path") ;;
    R*) echo "  ! rename is not supported by this toolkit: $path" >&2 ;;
  esac
done < <(git -C "$FROM" diff --name-status "$BASE")

# A brand-new file the developer has not `git add`ed yet is still part of the
# feature and must make it into modules/. Skipping untracked files here is how
# a toolkit silently ships without the file that was just written.
while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  is_shippable_path "$path" || continue
  added+=("$path")
done < <(git -C "$FROM" ls-files --others --exclude-standard)

if (( ${#deleted[@]} > 0 )); then
  echo "error: the feature deletes files that exist in the base commit:" >&2
  printf '  - %s\n' "${deleted[@]}" >&2
  echo "       Deletions cannot be replayed by apply.sh. Either restore the file" >&2
  echo "       or teach apply.sh a removal list before syncing." >&2
  exit 2
fi

stale=0

# --- modules/ ----------------------------------------------------------------
# Rewrite the whole directory so a file removed from the feature also leaves
# the toolkit. Copying file-by-file is not enough to express removal.
tmp_modules="$(mktemp -d)"
trap 'rm -rf "$tmp_modules"' EXIT
for path in "${added[@]}"; do
  mkdir -p "$tmp_modules/$(dirname "$path")"
  cp "$FROM/$path" "$tmp_modules/$path"
done

if [[ $CHECK -eq 1 ]]; then
  if ! diff -rq "$tmp_modules" "$HERE/modules" >/dev/null 2>&1; then
    echo "-- modules/: STALE"
    diff -rq "$tmp_modules" "$HERE/modules" 2>&1 | sed 's/^/     /' | head -40
    stale=1
  else
    echo "-- modules/: up to date (${#added[@]} files)"
  fi
else
  rm -rf "$HERE/modules"
  mkdir -p "$HERE/modules"
  cp -R "$tmp_modules/." "$HERE/modules/"
  echo "-- modules/: wrote ${#added[@]} files"
fi

# --- patches/ ----------------------------------------------------------------
# Name each patch after the file's full path with separators swapped for
# underscores, so the mapping stays reversible by reading the diff header.
tmp_patches="$(mktemp -d)"
trap 'rm -rf "$tmp_modules" "$tmp_patches"' EXIT
declare -a expected=()
for path in "${modified[@]}"; do
  safe="$(echo "$path" | tr '/' '_')"
  expected+=("${safe}.patch")
  git -C "$FROM" diff "$BASE" -- "$path" > "$tmp_patches/${safe}.patch"
done

if [[ $CHECK -eq 1 ]]; then
  issues=0
  for f in "${expected[@]}"; do
    [[ -f "$HERE/patches/$f" ]] || { echo "     missing: $f"; issues=1; }
  done
  while IFS= read -r p; do
    b="$(basename "$p")"
    found=0
    for f in "${expected[@]}"; do [[ "$f" == "$b" ]] && found=1 && break; done
    (( found )) || { echo "     orphaned: $b"; issues=1; }
  done < <(find "$HERE/patches" -name '*.patch')
  # A patch that no longer matches what the tree produces is worse than a
  # missing one: it applies cleanly and writes the wrong code.
  for f in "${expected[@]}"; do
    [[ -f "$HERE/patches/$f" ]] || continue
    cmp -s "$tmp_patches/$f" "$HERE/patches/$f" \
      || { echo "     content differs: $f"; issues=1; }
  done
  if (( issues )); then
    echo "-- patches/: STALE (${#modified[@]} expected)"
    stale=1
  else
    echo "-- patches/: up to date (${#modified[@]} files)"
  fi
else
  rm -rf "$HERE/patches"
  mkdir -p "$HERE/patches"
  # `cp dir/.` and not `cp dir/*.patch`: a glob expands without dotfiles, which
  # would silently drop patches whose target starts with a dot (.gitignore).
  cp -R "$tmp_patches/." "$HERE/patches/"
  echo "-- patches/: wrote ${#modified[@]} files"
fi

# --- BASE --------------------------------------------------------------------
# Recorded so apply.sh, test-cycle.sh and future readers all agree on which
# upstream revision these patches were cut against.
base_line="$BASE"
if [[ $CHECK -eq 1 ]]; then
  if [[ -f "$BASE_FILE" ]] && [[ "$(head -1 "$BASE_FILE" | awk '{print $1}')" == "$BASE" ]]; then
    echo "-- BASE: up to date"
  else
    echo "-- BASE: STALE (should be $BASE)"; stale=1
  fi
else
  git -C "$FROM" log -1 --format='%H%n%ad%n%s' --date=short "$BASE" > "$BASE_FILE"
  echo "-- BASE: recorded $base_line"
fi

echo
if (( stale )); then
  echo "== toolkit is STALE — rerun without --check =="
  exit 1
fi
echo "== toolkit matches the working tree =="
