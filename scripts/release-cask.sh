#!/bin/bash
# release-cask.sh <version> [--push]
# Update the Homebrew cask in ../homebrew-tap (or $ICA_TAP_DIR) to a published GitHub release.
# Downloads the release DMG and its .sha256 asset, checks that they agree and that the DMG carries the release
# team's Developer ID signature, notarized and stapled (ICA_TEAM_ID, default: this Mac's Developer ID identity),
# rewrites version and sha256 in Casks/icaviewer.rb, runs `brew style` on that file when it works without tapping, and commits in the tap.
# Pushes only with --push. Never taps, installs or trusts anything in the host's Homebrew.
set -euo pipefail
repo=${ICA_RELEASE_REPO:-JanHaan/swift-ica-client}
here=$(cd "$(dirname "$0")/.." && pwd)
tap=${ICA_TAP_DIR:-$here/../homebrew-tap}
version= push=0
for a in "$@"; do
    case $a in
        --push) push=1 ;;
        -*) echo "unknown option $a" >&2; exit 2 ;;
        *) version=$a ;;
    esac
done
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { sed -n '2,3p' "$0" >&2; echo "usage: release-cask.sh <x.y.z> [--push]" >&2; exit 2; }
cask=$tap/Casks/icaviewer.rb
[ -f "$cask" ] || { echo "no $cask (set ICA_TAP_DIR)" >&2; exit 1; }
git -C "$tap" diff --quiet HEAD -- || { echo "the tap has uncommitted changes; commit or stash them first" >&2; exit 1; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
dmg=swift-ica-client-$version.dmg
gh release download "v$version" -R "$repo" -p "$dmg" -p "$dmg.sha256" -D "$tmp"
sum=$(shasum -a 256 "$tmp/$dmg" | awk '{print $1}')
published=$(awk '{print $1; exit}' "$tmp/$dmg.sha256")
[ "$sum" = "$published" ] || { echo "SHA-256 mismatch: DMG $sum, release asset $published" >&2; exit 1; }
echo "sha256 $sum (matches the release's .sha256 asset)"

# The .sha256 asset comes from the same release as the DMG, so it only proves the download is whole. Before the cask
# pins the hash, the DMG must carry our own Developer ID signature, notarized and stapled: someone who could replace
# both assets (or a DMG of another, notarized team) is refused. The team comes from ICA_TEAM_ID or from the
# Developer ID identity in this Mac's keychain (the one make-dmg.sh signs with); it is not written into this file.
team=${ICA_TEAM_ID:-$(security find-identity -v -p codesigning 2>/dev/null |
    sed -n 's/.*"Developer ID Application: .* (\([A-Z0-9]\{10\}\))"$/\1/p' | head -1)}
[ -n "$team" ] || { echo "no Developer ID identity in the keychain: set ICA_TEAM_ID to the release's team" >&2; exit 1; }
codesign --verify --strict "$tmp/$dmg" 2>/dev/null || { echo "the DMG's signature does not verify" >&2; exit 1; }
dmg_team=$(codesign -dv "$tmp/$dmg" 2>&1 | sed -n 's/^TeamIdentifier=//p')
[ "$dmg_team" = "$team" ] || { echo "the DMG is signed by team '${dmg_team:-none}', not by the release team" >&2; exit 1; }
xcrun stapler validate -q "$tmp/$dmg" >/dev/null 2>&1 || { echo "the DMG has no valid stapled notarization ticket" >&2; exit 1; }
spctl -a -t open --context context:primary-signature "$tmp/$dmg" 2>/dev/null ||
    { echo "Gatekeeper rejects the DMG" >&2; exit 1; }
echo "DMG signed by the release team, notarized and stapled, accepted by Gatekeeper"

sed -i '' -e "s/^  version \".*\"/  version \"$version\"/" -e "s/^  sha256 \".*\"/  sha256 \"$sum\"/" "$cask"
grep -q "version \"$version\"" "$cask" && grep -q "sha256 \"$sum\"" "$cask" || { echo "could not rewrite $cask" >&2; exit 1; }

# brew style on a file path needs no tap; skip it when it does not run cleanly here.
if command -v brew >/dev/null 2>&1; then
    if out=$(cd /tmp && HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 brew style "$cask" 2>&1); then
        echo "brew style: $(echo "$out" | tail -1)"
    else
        echo "brew style reported problems or could not run:" >&2; echo "$out" >&2
        git -C "$tap" checkout -- Casks/icaviewer.rb; exit 1
    fi
else
    echo "note: brew not found, brew style skipped"
fi

if git -C "$tap" diff --quiet -- Casks/icaviewer.rb; then
    echo "the cask already says $version; nothing to commit"
else
    git -C "$tap" add Casks/icaviewer.rb
    git -C "$tap" commit -q -m "ICA Viewer cask $version"
    git -C "$tap" log --oneline -1
fi
if [ $push = 1 ]; then
    git -C "$tap" push
else
    echo "not pushed: review, then run 'git -C $tap push' (or rerun with --push)"
fi
