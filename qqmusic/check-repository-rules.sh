#!/usr/bin/env bash
set -euo pipefail
failures=0
pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }

active_docs=(README.md AGENTS.md CONTRIBUTING.md SECURITY.md NOTICE docs/README.md docs/dependencies.md docs/PITFALLS.md qqmusic/README.md qqmusic/RELEASING.md qqmusic/integration/README.md qqmusic/release/patch-README.template.md qqmusic/release/component-README.md Tools/helper-next/README.md)

if [[ -f AGENTS.md ]] && ! git check-ignore -q AGENTS.md; then pass 'root AGENTS.md is present and not ignored'; else fail 'root AGENTS.md is missing or ignored'; fi
if [[ -f LICENSE.txt ]] && grep -Fq '[LICENSE](LICENSE.txt)' README.md; then pass 'README links the tracked root license'; else fail 'README license link is broken'; fi

tracked_bins="$(git ls-files -- Tools/helper-next/qqmusic-helper-next Tools/helper-next/aria2-next qqmusic/integration/modules/Tools/helper-next/qqmusic-helper-next qqmusic/integration/modules/Tools/helper-next/aria2-next)"
[[ -z "$tracked_bins" ]] && pass 'runtime component binaries are not tracked' || { fail 'runtime component binaries are tracked:'; printf '%s\n' "$tracked_bins"; }

[[ -f qqmusic/integration/BASE ]] && pass 'integration BASE exists' || fail 'integration BASE missing'
[[ -f qqmusic/integration/components.lock.json ]] && /usr/bin/plutil -lint qqmusic/integration/components.lock.json >/dev/null && pass 'component lock is valid' || fail 'component lock missing or invalid'

for obsolete in .github/FUNDING.yml .github/workflows/deploy-pages.yml pages qqmusic/release/notes.md qqmusic/release/patch-README.md Tools/QQMusicHelper scripts/components/qqmusic-helper.sh kmgccc_player/Services/QQMusic/QQMusicHelperProcess.swift; do
  [[ ! -e "$obsolete" ]] || fail "obsolete repository surface remains: $obsolete"
done

legacy_pattern='Tools/QQMusicHelper|QQMusicWebAPI|docs/qqmusic|integration/GUIDE\.md|qqmusic-api-python==|Python helper'
hits="$(grep -nE "$legacy_pattern" "${active_docs[@]}" 2>/dev/null || true)"
[[ -z "$hits" ]] && pass 'active docs contain no retired implementation/local-note references' || { fail 'active docs contain retired implementation/local-note references:'; printf '%s\n' "$hits"; }

snapshot_pattern='b0de7aa6|QQMusic 1\.0\.0|QQMusic 1\.1\.0'
hits="$(grep -nE "$snapshot_pattern" "${active_docs[@]}" 2>/dev/null || true)"
[[ -z "$hits" ]] && pass 'long-lived docs contain no release/baseline snapshots' || { fail 'long-lived docs hardcode release/baseline snapshots:'; printf '%s\n' "$hits"; }

[[ -f qqmusic/RELEASING.md ]] && [[ ! -e qqmusic/release_plan.md ]] && pass 'release truth is qqmusic/RELEASING.md' || fail 'release truth is duplicated or missing'

grep -q 'static let patchVersion = "' kmgccc_player/Services/QQMusic/QQMusicComponentProcess.swift && pass 'production patchVersion source exists' || fail 'production patchVersion source missing'

if [[ "$failures" -eq 0 ]]; then echo 'all QQ Music repository rule checks passed'; exit 0; fi
printf '%d repository rule check(s) failed\n' "$failures"
exit 1
