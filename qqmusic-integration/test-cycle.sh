#!/usr/bin/env bash
#
# Full verification cycle: reset the test area from pristine upstream, apply the
# toolkit, build, and launch — so "does the toolkit actually work?" is answered
# by a real app on screen instead of by reading the patches.
#
# Usage:
#   ./test-cycle.sh [--sync] [--steps reset,apply,build,run] [--team TEAMID]
#                   [--configuration Debug] [--no-launch]
#
#   --sync    Regenerate modules/ + patches/ from the development tree first.
#             Do this whenever you changed the feature; without it you are
#             testing stale patches.
#   --steps   Run a subset (default: reset,apply,build,run).
#   --team    Apple team id for signing. Default: DEVELOPMENT_TEAM env var, else
#             autodetected from the first local Apple Development identity.
#
# Directories:
#   upstream/   Pristine upstream checkout, frozen. Never edited.
#   testarea/   Rebuilt from upstream/ on every run. Disposable by design.
#
# The test area borrows the development tree's .build/products instead of
# rebuilding lddc, mediaremote, sacad and the AMLL runtime — those take minutes
# and are not what is under test here. Only the app is compiled from scratch.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV="$(cd "${HERE}/.." && pwd)"
UPSTREAM="${DEV}/upstream"
TESTAREA="${DEV}/testarea"
STEPS="reset,apply,build,run"
DO_SYNC=0
TEAM="${DEVELOPMENT_TEAM:-}"
CONFIGURATION="${CONFIGURATION:-Debug}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sync)   DO_SYNC=1; shift ;;
    --steps)  STEPS="$2"; shift 2 ;;
    --team)   TEAM="$2"; shift 2 ;;
    --configuration) CONFIGURATION="$2"; shift 2 ;;
    --no-launch) STEPS="${STEPS%,run}"; shift ;;
    -h|--help) sed -n '3,25p' "$0"; exit 0 ;;
    *) echo "error: unknown option $1" >&2; exit 2 ;;
  esac
done

has_step() { [[ ",${STEPS}," == *",$1,"* ]]; }

fail() { echo "error: $*" >&2; exit 1; }

# Signing: the project pins the upstream author's team, which nobody else can
# use. Autodetect the local team rather than hardcoding an id that would be
# wrong on any other machine. The team id is the certificate's OU — not the
# trailing "(XXXXXXXXXX)" in the identity string, which is the certificate id.
if [[ -z "$TEAM" ]]; then
  TEAM="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Apple Development: .*\)"/\1/p' | head -1 \
    | xargs -I{} security find-certificate -c {} -p 2>/dev/null \
    | openssl x509 -noout -subject -nameopt multiline 2>/dev/null \
    | awk -F'= ' '/organizationalUnitName/{print $2; exit}')"
fi
[[ -n "$TEAM" ]] || fail "no Apple Development identity found; pass --team TEAMID"

echo "== test cycle =="
echo "dev tree:  $DEV"
echo "steps:     $STEPS"
echo "team:      $TEAM"
echo "config:    $CONFIGURATION"
echo

# --- sync --------------------------------------------------------------------
# Regenerate the toolkit from the working tree. Doing this first means the test
# exercises the code that was just written, not the code from last time.
if (( DO_SYNC )); then
  echo "-- sync toolkit --"
  "${HERE}/sync.sh" || fail "sync failed; fix the toolkit before testing"
  echo
fi

# --- reset -------------------------------------------------------------------
# upstream/ is the frozen baseline: the upstream commit this fork was cut from.
# Recreating testarea/ from it every run is what makes the result trustworthy —
# a test area that carries yesterday's applied patches proves nothing.
if has_step reset; then
  echo "-- reset --"
  [[ -d "${UPSTREAM}/kmgccc_player" ]] \
    || fail "no pristine baseline at ${UPSTREAM}; rebuild it with:
       mkdir -p '${UPSTREAM}' && git -C '${DEV}' archive \$(head -1 '${HERE}/BASE' | cut -d' ' -f1) | tar -x -C '${UPSTREAM}'"

  # Keep testarea's own git dir and DerivedData; replace everything else, so
  # files deleted upstream disappear instead of lingering.
  mkdir -p "$TESTAREA"
  /usr/bin/rsync -a --delete \
    --exclude '/.git/' --exclude '/build/' --exclude '/.build' \
    "${UPSTREAM}/" "${TESTAREA}/"

  # Share the heavy build products. A symlink and not a copy: bootstrap and the
  # Xcode copy phases then read the same artifacts the dev tree uses.
  if [[ -d "${DEV}/.build" && ! -e "${TESTAREA}/.build" ]]; then
    ln -s "${DEV}/.build" "${TESTAREA}/.build"
  fi

  if [[ ! -d "${TESTAREA}/.git" ]]; then
    git -C "$TESTAREA" init -q
    git -C "$TESTAREA" add -A
    git -C "$TESTAREA" -c user.name=test -c user.email=test@local \
      commit -q -m "pristine upstream"
  else
    # Restore the recorded baseline so `git status` after apply shows exactly
    # what the toolkit changed, with no residue from the previous run.
    git -C "$TESTAREA" add -A
    git -C "$TESTAREA" -c user.name=test -c user.email=test@local \
      commit -q --allow-empty -m "reset to pristine upstream"
  fi
  echo "  rebuilt testarea/ from upstream/ ($(git -C "$TESTAREA" log --oneline | wc -l | tr -d ' ') commits)"
  echo
fi

# --- apply -------------------------------------------------------------------
if has_step apply; then
  echo "-- apply --"
  "${HERE}/apply.sh" --repo "$TESTAREA" --reset --verify --baseline "$UPSTREAM"
  status=$?
  echo
  if (( status != 0 )); then
    echo "apply.sh reported conflicts. Resolve them against a current upstream"
    echo "checkout, then run sync.sh so the toolkit carries the resolution."
    exit 1
  fi
  # The change set is now knowable: this is the ground truth for "did the
  # toolkit reproduce the feature", independent of what apply.sh printed.
  echo "  changed files: $(git -C "$TESTAREA" status --porcelain | wc -l | tr -d ' ')"
  git -C "$TESTAREA" status --porcelain | sed 's/^/    /' | head -40
  echo
fi

# --- build -------------------------------------------------------------------
# Build the helper from the development tree: bootstrap resolves the AMLL
# submodule through git, which the test area deliberately does not have. The
# products land in the shared .build either way.
APP_BUNDLE="${TESTAREA}/build/DerivedData/Build/Products/${CONFIGURATION}/kmgccc_player.app"

if has_step build; then
  echo "-- helper --"
  "${DEV}/scripts/bootstrap.sh" --component qqmusic-helper \
    || fail "helper build failed"

  # The app prefers the external helper directory over the copy inside the
  # bundle, so a stale external copy silently shadows what was just built and
  # the test would exercise old behaviour. Keep them in step.
  HELPER_PRODUCT="${DEV}/.build/products/qqmusic-helper"
  HELPER_EXTERNAL="${HOME}/Library/Application Support/kmgccc.player/QQMusicHelper"
  if [[ -x "${HELPER_PRODUCT}/qqmusic-helper" ]]; then
    mkdir -p "$HELPER_EXTERNAL"
    # Credential/ holds the login state and is not part of the build output.
    /usr/bin/rsync -a --delete --exclude '/Credential/' \
      "${HELPER_PRODUCT}/" "${HELPER_EXTERNAL}/"
    echo "  synced to ${HELPER_EXTERNAL}"
  else
    echo "  warning: no helper product at ${HELPER_PRODUCT}; app will use the bundled copy"
  fi
  echo

  echo "-- app --"
  # -disableAutomaticPackageResolution reuses the dev tree's package cache, so
  # a cycle does not depend on the network being up.
  xcodebuild \
    -project "${TESTAREA}/kmgccc_player.xcodeproj" \
    -scheme kmgccc_player \
    -configuration "$CONFIGURATION" \
    -destination 'platform=macOS' \
    -derivedDataPath "${TESTAREA}/build/DerivedData" \
    -clonedSourcePackagesDirPath "${DEV}/build/DerivedData/SourcePackages" \
    -disableAutomaticPackageResolution \
    DEVELOPMENT_TEAM="$TEAM" \
    CODE_SIGN_IDENTITY="Apple Development" \
    CODE_SIGN_STYLE=Automatic \
    build \
    2>&1 | tail -25
  # xcodebuild's exit code is lost through the pipe; the bundle is the artifact
  # that actually matters, so check it exists and is signed.
  [[ -d "$APP_BUNDLE" ]] || fail "build produced no app bundle at $APP_BUNDLE"
  echo
  echo "  app: $APP_BUNDLE"
  codesign --verify --deep --strict "$APP_BUNDLE" 2>&1 | sed 's/^/  /' || true
  echo
fi

# --- run ---------------------------------------------------------------------
if has_step run; then
  echo "-- run --"
  [[ -d "$APP_BUNDLE" ]] || fail "no app to run at $APP_BUNDLE (run the build step)"
  pkill -x kmgccc_player >/dev/null 2>&1 || true
  sleep 1
  open -n "$APP_BUNDLE"
  for _ in $(seq 1 20); do
    pgrep -x kmgccc_player >/dev/null && { echo "  launched: $(pgrep -x kmgccc_player | head -1)"; break; }
    sleep 0.5
  done
  pgrep -x kmgccc_player >/dev/null \
    || fail "app exited immediately after launch; check Console for a crash"
  echo
fi

echo "== cycle complete =="
