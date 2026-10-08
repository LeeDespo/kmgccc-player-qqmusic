#!/usr/bin/env bash
set -euo pipefail

QQMUSIC_LOCK="${QQMUSIC_COMPONENT_LOCK:-$ROOT/qqmusic/integration/components.lock.json}"
QQMUSIC_TOOLS="$ROOT/Tools/helper-next"
QQMUSIC_LICENSES="$ROOT/kmgccc_player/Resources/Licenses"
QQMUSIC_WORK="$WORK_DIR/qqmusic"

# The lock is JSON, not an Apple plist. Parse it with the Python standard
# library (already required by the complete macOS build), not plutil.
qqmusic_lock_value() {
  python3 - "$QQMUSIC_LOCK" "$1" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as lock_file:
    value = json.load(lock_file)
for key in sys.argv[2].split("."):
    value = value[key]
print(value)
PY
}

qqmusic_require_lock() {
  [[ -f "$QQMUSIC_LOCK" ]] || bootstrap_fail QQMusic "Component lock missing: $QQMUSIC_LOCK"
  python3 -m json.tool "$QQMUSIC_LOCK" >/dev/null || bootstrap_fail QQMusic "Component lock is not valid JSON."
}

qqmusic_check() {
  qqmusic_require_lock
  local helper_version protocol aria_version aria_sha helper_answer
  helper_version="$(qqmusic_lock_value helperNext.version)"
  protocol="$(qqmusic_lock_value helperNext.protocolVersion)"
  aria_version="$(qqmusic_lock_value aria2Next.version)"
  aria_sha="$(qqmusic_lock_value aria2Next.sha256)"

  [[ -x "$QQMUSIC_TOOLS/qqmusic-helper-next" ]] || bootstrap_fail QQMusic "HelperNext is not materialized." "Run ./scripts/bootstrap.sh --component qqmusic"
  [[ -x "$QQMUSIC_TOOLS/aria2-next" ]] || bootstrap_fail QQMusic "Aria2 Next is not materialized." "Run ./scripts/bootstrap.sh --component qqmusic"
  is_arm64_macho "$QQMUSIC_TOOLS/qqmusic-helper-next" || bootstrap_fail QQMusic "HelperNext is not an arm64 Mach-O executable."
  is_arm64_macho "$QQMUSIC_TOOLS/aria2-next" || bootstrap_fail QQMusic "Aria2 Next is not an arm64 Mach-O executable."
  [[ "$(sha256_file "$QQMUSIC_TOOLS/aria2-next")" == "$aria_sha" ]] || bootstrap_fail QQMusic "Aria2 Next checksum does not match the lock."

  helper_answer="$("$QQMUSIC_TOOLS/qqmusic-helper-next" --version 2>/dev/null || true)"
  [[ "$helper_answer" == "qqmusic-helper-next $helper_version (protocol $protocol)" ]] || bootstrap_fail QQMusic "HelperNext version/protocol does not match the lock: $helper_answer"

  for file in QQMusicApi_HelperNext-GPL-3.0.txt QQMusicApi_HelperNext-NOTICE.txt QQMusicApi_HelperNext-THIRD-PARTY-LICENSES.txt Aria2Next-GPL-2.0.txt; do
    [[ -s "$QQMUSIC_LICENSES/$file" ]] || bootstrap_fail QQMusic "Generated license file missing: $file"
  done
  [[ -f "$QQMUSIC_TOOLS/manifest.json" ]] || bootstrap_fail QQMusic "HelperNext release manifest is missing."
  [[ -f "$QQMUSIC_TOOLS/components.lock.json" ]] && /usr/bin/cmp -s "$QQMUSIC_LOCK" "$QQMUSIC_TOOLS/components.lock.json" || bootstrap_fail QQMusic "Materialized component lock is stale."

  component_log QQMusic "ready (HelperNext $helper_version / protocol $protocol; Aria2 Next $aria_version)"
}

qqmusic_prepare() {
  qqmusic_require_lock

  local helper_asset helper_sha helper_url aria_asset aria_sha aria_url aria_license_url aria_license_blob
  helper_asset="$(qqmusic_lock_value helperNext.asset)"
  helper_sha="$(qqmusic_lock_value helperNext.sha256)"
  helper_url="$(qqmusic_lock_value helperNext.url)"
  aria_asset="$(qqmusic_lock_value aria2Next.asset)"
  aria_sha="$(qqmusic_lock_value aria2Next.sha256)"
  aria_url="$(qqmusic_lock_value aria2Next.url)"
  aria_license_url="$(qqmusic_lock_value aria2Next.licenseUrl)"
  aria_license_blob="$(qqmusic_lock_value aria2Next.licenseGitBlobSha)"

  local helper_archive="$DOWNLOADS_DIR/$helper_asset"
  local aria_download="$DOWNLOADS_DIR/$aria_asset"
  local aria_license="$DOWNLOADS_DIR/aria2-next-COPYING-$aria_license_blob"

  download_checked QQMusic "$helper_url" "$helper_sha" "$helper_archive"
  download_checked QQMusic "$aria_url" "$aria_sha" "$aria_download"

  if [[ ! -f "$aria_license" ]] || [[ "$(git hash-object "$aria_license" 2>/dev/null || true)" != "$aria_license_blob" ]]; then
    rm -f "$aria_license"
    run_logged QQMusic license 120 /usr/bin/curl --fail --location --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 110 --silent --show-error "$aria_license_url" -o "$aria_license"
  fi
  [[ "$(git hash-object "$aria_license")" == "$aria_license_blob" ]] || bootstrap_fail QQMusic "Aria2 Next license content does not match the locked Git blob."

  rm -rf "$QQMUSIC_WORK"
  mkdir -p "$QQMUSIC_WORK" "$QQMUSIC_TOOLS" "$QQMUSIC_LICENSES"
  /usr/bin/tar -xzf "$helper_archive" -C "$QQMUSIC_WORK"

  local helper_binary helper_stage
  helper_binary="$(/usr/bin/find "$QQMUSIC_WORK" -type f -name qqmusic-helper-next -print -quit)"
  [[ -n "$helper_binary" ]] || bootstrap_fail QQMusic "HelperNext archive contains no qqmusic-helper-next binary."
  helper_stage="$(dirname "$helper_binary")"
  for file in LICENSE NOTICE THIRD-PARTY-LICENSES.txt manifest.json; do
    [[ -f "$helper_stage/$file" ]] || bootstrap_fail QQMusic "HelperNext archive missing $file."
  done

  install_if_changed "$helper_binary" "$QQMUSIC_TOOLS/qqmusic-helper-next"
  install_if_changed "$aria_download" "$QQMUSIC_TOOLS/aria2-next"
  install_if_changed "$helper_stage/manifest.json" "$QQMUSIC_TOOLS/manifest.json"
  install_if_changed "$QQMUSIC_LOCK" "$QQMUSIC_TOOLS/components.lock.json"
  install_if_changed "$helper_stage/LICENSE" "$QQMUSIC_LICENSES/QQMusicApi_HelperNext-GPL-3.0.txt"
  install_if_changed "$helper_stage/NOTICE" "$QQMUSIC_LICENSES/QQMusicApi_HelperNext-NOTICE.txt"
  install_if_changed "$helper_stage/THIRD-PARTY-LICENSES.txt" "$QQMUSIC_LICENSES/QQMusicApi_HelperNext-THIRD-PARTY-LICENSES.txt"
  install_if_changed "$aria_license" "$QQMUSIC_LICENSES/Aria2Next-GPL-2.0.txt"
  /bin/chmod 755 "$QQMUSIC_TOOLS/qqmusic-helper-next" "$QQMUSIC_TOOLS/aria2-next"
  /usr/bin/xattr -cr "$QQMUSIC_TOOLS" "$QQMUSIC_LICENSES/QQMusicApi_HelperNext-GPL-3.0.txt" "$QQMUSIC_LICENSES/QQMusicApi_HelperNext-NOTICE.txt" "$QQMUSIC_LICENSES/QQMusicApi_HelperNext-THIRD-PARTY-LICENSES.txt" "$QQMUSIC_LICENSES/Aria2Next-GPL-2.0.txt" 2>/dev/null || true

  qqmusic_check
}
