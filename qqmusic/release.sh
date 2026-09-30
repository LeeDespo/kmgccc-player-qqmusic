#!/usr/bin/env bash
#
# Package a release: the built app as a DMG, plus the patch package as a tarball.
#
# Usage:
#   ./qqmusic/release.sh [--patch-version 1.0.0] [--out DIR] [--skip-build]
#
# What it does, in order:
#
#   1. syncs the patch toolkit from the working tree (`sync.sh`) so the shipped
#      patch package cannot be older than the shipped app — the failure this
#      avoids is silent: a stale toolkit applies cleanly and builds an app
#      without the newest fixes;
#   2. builds the app in Release for arm64 (the architecture upstream supports),
#      unsigned: this fork has no developer account, so the DMG cannot be
#      notarised, and the installer note says how to get past Gatekeeper;
#   3. stamps the built bundle with the commit and time (see below);
#   4. writes the installer note and builds the DMG (drag to /Applications);
#   5. packs the patch package as a tarball, with a consumer-facing README.
#
# Why the stamp is written here rather than trusted to the build phase: the
# "Stamp QQ Music build" phase writes into the app's Info.plist during the build,
# and an incremental build can re-run the plist processing step *after* it, which
# silently drops the stamp — observed, not theoretical. The stamp is what tells a
# stale build from an unfixed bug, so the release writes it once more and fails if
# it is not in the shipped bundle.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCH_VERSION=""
# Deliberately not `build/release`: macOS filesystems are case-insensitive, so
# that path *is* `build/Release` — the derived data directory holding the app
# this script is about to package, which `rm -rf $OUT_DIR` would delete.
OUT_DIR="$REPO_ROOT/build/dist"
SKIP_BUILD=0
UPSTREAM_BASE="b0de7aa6"

while (($# > 0)); do
    case "$1" in
        --patch-version) PATCH_VERSION="$2"; shift 2 ;;
        --out)           OUT_DIR="$2"; shift 2 ;;
        --skip-build)    SKIP_BUILD=1; shift ;;
        -h|--help)       sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) printf 'error: unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done

fail() { printf 'error: %s\n' "$1" >&2; exit 1; }
step() { printf '\n== %s ==\n' "$1"; }

# The patch's own version is a constant in the source, so the DMG's name, the
# tarball's name and what the app reports under 本功能版本 cannot disagree.
if [[ -z "$PATCH_VERSION" ]]; then
    PATCH_VERSION="$(
        sed -n 's/.*static let patchVersion = "\([^"]*\)".*/\1/p' \
            "$REPO_ROOT/kmgccc_player/Services/QQMusic/QQMusicHelperProcess.swift" | head -1
    )"
fi
[[ -n "$PATCH_VERSION" ]] || fail "could not read patchVersion from the source; pass --patch-version"

# The app's own version is upstream's; read it so the release name states the
# baseline honestly ("2.3.1 + QQMusic 1.0.0").
UPSTREAM_VERSION="$(
    sed -n 's/.*MARKETING_VERSION = \([0-9.]*\);.*/\1/p' \
        "$REPO_ROOT/kmgccc_player.xcodeproj/project.pbxproj" | head -1
)"
[[ -n "$UPSTREAM_VERSION" ]] || fail "could not read MARKETING_VERSION from the project"

RELEASE_NAME="${UPSTREAM_VERSION} + QQMusic ${PATCH_VERSION}"
SLUG="${UPSTREAM_VERSION}+QQMusic.${PATCH_VERSION}"
DERIVED="$REPO_ROOT/build/Release"
APP="$DERIVED/Build/Products/Release/kmgccc_player.app"

step "release ${RELEASE_NAME}"
printf 'repo:    %s\n' "$REPO_ROOT"
printf 'out:     %s\n' "$OUT_DIR"

step "sync patch toolkit"
"$REPO_ROOT/qqmusic/integration/sync.sh"
"$REPO_ROOT/qqmusic/integration/sync.sh" --check

if ((SKIP_BUILD == 0)); then
    step "build (Release, arm64, unsigned)"
    xcodebuild \
        -project "$REPO_ROOT/kmgccc_player.xcodeproj" \
        -scheme kmgccc_player \
        -configuration Release \
        -destination 'platform=macOS,arch=arm64' \
        -derivedDataPath "$DERIVED" \
        BUILD_EXTENSION_MODE=disabled \
        CODE_SIGNING_ALLOWED=NO \
        build
else
    step "build skipped"
fi

[[ -d "$APP" ]] || fail "app was not produced: $APP"
[[ -x "$APP/Contents/MacOS/kmgccc_player" ]] || fail "app binary missing"
[[ -x "$APP/Contents/Resources/Tools/qqmusic-helper-next/qqmusic-helper-next" ]] \
    || fail "the bundle has no QQ Music data component (Tools/helper-next/qqmusic-helper-next)"
"$REPO_ROOT/scripts/check-app-bundle.sh" "$APP"

step "stamp, sign, verify"
COMMIT="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
DIRTY=""
git -C "$REPO_ROOT" diff --quiet 2>/dev/null || DIRTY="+"
STAMP="${COMMIT}${DIRTY} $(date '+%Y-%m-%d %H:%M')"
PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :QQMusicBuildStamp" "$PLIST" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :QQMusicBuildStamp string ${STAMP}" "$PLIST" >/dev/null
WRITTEN="$(/usr/libexec/PlistBuddy -c "Print :QQMusicBuildStamp" "$PLIST")"
[[ "$WRITTEN" == "$STAMP" ]] || fail "the stamp did not stick (expected '${STAMP}', found '${WRITTEN}')"
printf 'stamped: %s\n' "$STAMP"

# Ad-hoc sign the bundle, *after* the stamp so the sealed manifest covers it.
#
# `CODE_SIGNING_ALLOWED=NO` leaves the main binary carrying the linker's ad-hoc
# signature while the bundle has no sealed resources — and macOS reads that
# mismatch as "code has no resources but signature indicates they must be
# present", i.e. a damaged app. The documented Gatekeeper bypass (right-click →
# open, or clearing the quarantine attribute) does not fix a *broken* signature,
# so a release built that way greets every downloader with 应用已损坏.
#
# An ad-hoc signature is not a trust signature: Gatekeeper still refuses the
# first launch, which is why the installer note explains how to allow it. What it
# buys is a bundle whose signature is consistent with its contents.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 \
    || fail "ad-hoc signing failed"
codesign --verify --deep --strict "$APP" >/dev/null 2>&1 \
    || fail "the signed bundle does not verify"
printf 'signed:  ad-hoc (%s)\n' "$(codesign -dv "$APP" 2>&1 | sed -n 's/^Signature=//p')"

step "assemble DMG"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR/dmg"
COPYFILE_DISABLE=1 /usr/bin/ditto "$APP" "$OUT_DIR/dmg/kmgccc_player.app"
ln -s /Applications "$OUT_DIR/dmg/Applications"
cat > "$OUT_DIR/dmg/安装说明.txt" <<EOF
kmgccc_player ${UPSTREAM_VERSION} + QQMusic ${PATCH_VERSION}
$(printf '=%.0s' $(seq 1 46))

把 kmgccc_player.app 拖到右侧的「应用程序」文件夹即可。

首次打开
--------
本应用没有 Apple 开发者账号签名，也没有公证，从网上下载后 macOS 会拦住它。
任选一种方式放行：

  1. 在「应用程序」里右键点它 → 打开 → 再点「打开」；
  2. 或者在终端里执行一次：
     xattr -dr com.apple.quarantine /Applications/kmgccc_player.app

系统要求
--------
macOS 26.0 或更新版本，Apple Silicon Mac。

第一次使用 QQ 音乐
------------------
启动后点侧边栏最下面的「QQ 音乐」，用手机 QQ 扫码登录（或网页登录）。
在线歌曲会先下载到本地曲库再播放，因此需要「托管」资料库——原位引用
模式的资料库只能浏览、不能下载。

说明
----
- 本应用关闭了自动更新、崩溃上报与匿名统计：更新源属于上游项目，
  崩溃与统计会发到上游作者的服务器，而对方无法据此做任何事。
- 本构建：$STAMP
- 完整说明与补丁包：https://github.com/LeeDespo/kmgccc-player-qqmusic
EOF
DMG="$OUT_DIR/kmgccc_player-${SLUG}-arm64.dmg"
hdiutil create -volname "kmgccc_player ${RELEASE_NAME}" \
    -srcfolder "$OUT_DIR/dmg" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
rm -rf "$OUT_DIR/dmg"

step "assemble patch package"
PKG="$OUT_DIR/patch/kmgccc_player-${SLUG}-patch"
rm -rf "$OUT_DIR/patch"
mkdir -p "$PKG"
cp -R "$REPO_ROOT/qqmusic/integration" "$PKG/integration"
rm -f "$PKG/integration/GUIDE.md"
cp "$REPO_ROOT/qqmusic/README.md" "$PKG/FEATURES.md"
cp "$REPO_ROOT/qqmusic/release/patch-README.md" "$PKG/README.md"
find "$PKG" -name '.DS_Store' -delete
( cd "$OUT_DIR/patch" && COPYFILE_DISABLE=1 tar -czf "../kmgccc_player-${SLUG}-patch.tar.gz" "$(basename "$PKG")" )
TARBALL="$OUT_DIR/kmgccc_player-${SLUG}-patch.tar.gz"
rm -rf "$OUT_DIR/patch"

step "artifacts"
printf 'dmg:     %s\n' "$DMG"
printf 'patch:   %s\n' "$TARBALL"
printf 'baseline: %s\n' "$UPSTREAM_BASE"
printf 'commit:   %s\n' "$STAMP"
( cd "$OUT_DIR" && shasum -a 256 "$(basename "$DMG")" "$(basename "$TARBALL")" )
