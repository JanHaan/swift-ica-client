#!/bin/sh
# Release build: universal (arm64 + x86_64) ICAViewer.app in a compressed DMG with a SHA-256 file.
# Usage: scripts/make-dmg.sh [version]   → .build/dist/swift-ica-client-<version>.dmg (+ .sha256)
# Version defaults to the one in bundle.sh. Only writes under .build/dist/.
#
# Default: ad-hoc signature (no profile, no entitlements, no development identity).
# Notarized release: ICA_SIGN=developer-id (or ICA_SIGN_IDENTITY="Developer ID Application: …"),
#   optional ICA_RELEASE_PROFILE=<Developer ID .provisionprofile> for Keychain-enforced Touch ID,
#   ICA_NOTARY_PROFILE=<name from `xcrun notarytool store-credentials`> to notarize and staple.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
version="${1:-${ICA_VERSION:-0.1}}"
dist="$root/.build/dist"
app="$dist/ICAViewer.app"
dmg="$dist/swift-ica-client-$version.dmg"

die() { echo "error: $*" >&2; exit 1; }
developer_id_listing() { security find-identity -v -p codesigning | grep 'Developer ID Application' || true; }

# Signing mode, validated before the long build.
if [ -z "${ICA_SIGN:-}" ] && [ -n "${ICA_SIGN_IDENTITY:-}" ] &&
    developer_id_listing | grep -qF "$ICA_SIGN_IDENTITY"; then
    ICA_SIGN=developer-id
fi
mode="${ICA_SIGN:-adhoc}"
identity=""
case "$mode" in
adhoc) ;;
developer-id)
    identity="${ICA_SIGN_IDENTITY:-$(developer_id_listing | awk '{ print $2; exit }')}"
    [ -n "$identity" ] || die "no Developer ID Application identity in the keychain.
  Create one in Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application,
  then rerun (or set ICA_SIGN_IDENTITY)."
    if [ -n "${ICA_RELEASE_PROFILE:-}" ]; then
        [ -f "$ICA_RELEASE_PROFILE" ] || die "ICA_RELEASE_PROFILE not found: $ICA_RELEASE_PROFILE
  Create a 'Developer ID' provisioning profile for local.alttab.ICAViewer at developer.apple.com."
    fi
    if [ -n "${ICA_NOTARY_PROFILE:-}" ]; then
        xcrun --find notarytool >/dev/null 2>&1 || die "xcrun notarytool not found (install Xcode 13+)"
    else
        echo "note: ICA_NOTARY_PROFILE not set; the DMG will be signed but not notarized." >&2
        echo "      Store credentials once: xcrun notarytool store-credentials <name> --apple-id … --team-id …" >&2
    fi
    ;;
*) die "unknown ICA_SIGN=$mode (adhoc or developer-id)" ;;
esac
notarize=""
[ "$mode" = developer-id ] && [ -n "${ICA_NOTARY_PROFILE:-}" ] && notarize=1

rm -rf "$dist"
mkdir -p "$dist"
export ICA_SIGN="$mode" ICA_VERSION="$version" ICA_BUNDLE_OUT="$dist"
[ -z "$identity" ] || export ICA_SIGN_IDENTITY="$identity"

archs="arm64 x86_64"
ICA_SWIFT_FLAGS="--arch arm64 --arch x86_64"
export ICA_SWIFT_FLAGS
if ! "$root/scripts/bundle.sh" release >/dev/null; then
    [ ! -d "$app" ] || [ "$mode" = adhoc ] || die "signing failed"
    echo "note: universal build failed; falling back to arm64 only" >&2
    archs="arm64"
    ICA_SWIFT_FLAGS=""
    "$root/scripts/bundle.sh" release >/dev/null
fi

codesign --verify --deep --strict "$app"
actual="$(lipo -archs "$app/Contents/MacOS/ICAViewer")"
echo "architectures: $actual (requested: $archs)"
if [ "$mode" = adhoc ] || [ -z "${ICA_RELEASE_PROFILE:-}" ]; then
    [ ! -e "$app/Contents/embedded.provisionprofile" ] || die "provisioning profile in bundle"
fi
if [ "$mode" = developer-id ]; then
    codesign -dv "$app" 2>&1 | grep -q 'flags=.*runtime' || die "hardened runtime missing"
    codesign -d --entitlements - "$app" 2>/dev/null | grep -q get-task-allow && die "get-task-allow in release entitlements"
fi

stage="$(mktemp -d "$dist/stage.XXXXXX")"
mnt=""
cleanup() { [ -z "$mnt" ] || hdiutil detach "$mnt" -quiet 2>/dev/null || true; rm -rf "$stage"; }
trap cleanup EXIT
cp -R "$app" "$stage/ICAViewer.app"
ln -s /Applications "$stage/Applications"
if [ -n "${ICA_RELEASE_PROFILE:-}" ] && [ "$mode" = developer-id ]; then
    keychain_note="Saved secrets: Touch ID protection is enforced by the Keychain itself."
else
    keychain_note="Saved secrets: this build has no Keychain entitlements, so Touch ID protection of
Keychain-stored secrets uses the app-enforced mode (the app asks for Touch ID itself before
reading the secret) rather than Keychain-enforced access control."
fi
if [ -n "$notarize" ]; then
    gatekeeper_note="Signed with a Developer ID and notarized by Apple; it opens like any other app."
else
    gatekeeper_note="This build is not notarized (ad-hoc or unnotarized signature), so macOS blocks the first launch.
Since macOS 15 (Sequoia) right-click > Open no longer bypasses this. Either:
  - after the first blocked launch, open System Settings > Privacy & Security and click
    \"Open Anyway\" for ICAViewer, or
  - run: xattr -dr com.apple.quarantine /Applications/ICAViewer.app
Building from source (scripts/bundle.sh) avoids the prompt entirely."
fi
cat >"$stage/README.txt" <<README
ICAViewer $version (swift-ica-client)

An independent, native macOS client for ICA/HDX sessions. It is not affiliated with,
endorsed by or derived from Citrix software. Requires macOS 14 or later.

Install: drag ICAViewer.app to Applications.

$gatekeeper_note

$keychain_note
README

# Build-machine paths in the binary are reported, not fatal.
bin="$app/Contents/MacOS/ICAViewer"
leaks="$(strings -a "$bin" | grep -c '/Users/' || true)"
echo "strings with /Users/ in the binary: $leaks"
[ "$leaks" -eq 0 ] || strings -a "$bin" | grep '/Users/' | sort -u | head -5

hdiutil create -volname "ICAViewer $version" -srcfolder "$stage" -ov -format UDZO "$dmg" >/dev/null

if [ "$mode" = developer-id ]; then
    codesign --force --timestamp --sign "$identity" "$dmg"
    codesign --verify --strict "$dmg"
fi

status="ad-hoc signed, not notarized"
if [ -n "$notarize" ]; then
    echo "notarizing (this waits for Apple)…"
    result="$(xcrun notarytool submit "$dmg" --keychain-profile "$ICA_NOTARY_PROFILE" --wait --output-format json)" ||
        { echo "$result" >&2; die "notarytool submit failed"; }
    id="$(printf '%s' "$result" | plutil -extract id raw -o - - 2>/dev/null || true)"
    st="$(printf '%s' "$result" | plutil -extract status raw -o - - 2>/dev/null || true)"
    if [ "$st" != Accepted ]; then
        echo "notarization status: ${st:-unknown}" >&2
        [ -z "$id" ] || xcrun notarytool log "$id" --keychain-profile "$ICA_NOTARY_PROFILE" >&2 || true
        die "notarization failed"
    fi
    xcrun stapler staple "$dmg"
    xcrun stapler validate "$dmg"
    spctl -a -t open --context context:primary-signature -vv "$dmg"
    mnt="$(mktemp -d "$dist/mnt.XXXXXX")"
    hdiutil attach "$dmg" -nobrowse -readonly -mountpoint "$mnt" -quiet
    spctl -a -vv "$mnt/ICAViewer.app"
    hdiutil detach "$mnt" -quiet && mnt=""
    status="Developer ID signed, notarized and stapled"
elif [ "$mode" = developer-id ]; then
    status="Developer ID signed, NOT notarized (set ICA_NOTARY_PROFILE)"
fi
(cd "$dist" && shasum -a 256 "$(basename "$dmg")" >"$(basename "$dmg").sha256")

echo "status: $status"
echo "app:    $app"
echo "dmg:    $dmg ($(du -h "$dmg" | awk '{print $1}'))"
echo "sha256: $dmg.sha256 ($(cut -d' ' -f1 "$dmg.sha256"))"
echo "archs:  $actual"
