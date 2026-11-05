#!/bin/sh
# Builds ICAViewer and wraps the executable into ICAViewer.app (bundle identity, Info.plist,
# ad-hoc signature) so it runs as a regular app: Dock icon, AX application, window switchers.
# Usage: scripts/bundle.sh [release|debug]   → .build/ICAViewer.app (release by default: the
# Thinwire pixel loops are far too slow unoptimised for a session that repaints ~20 times a second)
# Environment (all optional; scripts/make-dmg.sh sets them for release builds):
#   ICA_BUNDLE_OUT=<dir>   directory to put ICAViewer.app in (default .build)
#   ICA_SIGN=adhoc         ad-hoc signature only: no provisioning profile, no entitlements
#   ICA_SIGN=developer-id  release signature (hardened runtime, secure timestamp, no get-task-allow)
#                          with ICA_SIGN_IDENTITY (default: first "Developer ID Application" identity);
#                          implied when ICA_SIGN_IDENTITY names such an identity. Entitlements:
#                          signing/ICAViewer.release.entitlements; with ICA_RELEASE_PROFILE=<Developer ID
#                          provisioning profile> that profile is embedded and the Keychain group added.
#                          Never uses signing/ICAViewer.provisionprofile (development, device-bound).
#   ICA_VERSION=<x.y>      CFBundleShortVersionString (default 0.1)
#   ICA_SWIFT_FLAGS=<...>  extra swift build flags (word-split), e.g. "--arch arm64 --arch x86_64"
set -eu
config="${1:-release}"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
version="${ICA_VERSION:-0.1}"
# shellcheck disable=SC2086
swift build -c "$config" --product ICAViewer ${ICA_SWIFT_FLAGS:-}
# shellcheck disable=SC2086
bin="$(swift build -c "$config" --show-bin-path ${ICA_SWIFT_FLAGS:-})/ICAViewer"
out="${ICA_BUNDLE_OUT:-$root/.build}"
mkdir -p "$out"
app="$(cd "$out" && pwd)/ICAViewer.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/ICAViewer"
cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.alttab.ICAViewer</string>
    <key>CFBundleName</key><string>ICAViewer</string>
    <key>CFBundleDisplayName</key><string>ICA Viewer</string>
    <key>CFBundleExecutable</key><string>ICAViewer</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
</dict>
</plist>
EOF
# Signing: with signing/ICAViewer.provisionprofile (scripts/fetch-profile.sh) and an Apple Development
# identity, sign with hardened runtime and the Keychain entitlements (Keychain-enforced Touch ID for
# saved secrets). Otherwise ad-hoc: the app works, but protects saved secrets itself.
profile="$root/signing/ICAViewer.provisionprofile"
bundle_id="local.alttab.ICAViewer"
developer_id_listing() { security find-identity -v -p codesigning | grep 'Developer ID Application' || true; }
if [ -z "${ICA_SIGN:-}" ] && [ -n "${ICA_SIGN_IDENTITY:-}" ] &&
    developer_id_listing | grep -qF "$ICA_SIGN_IDENTITY"; then
    ICA_SIGN=developer-id
fi
# Release signing for distribution outside the App Store (Developer ID, notarizable). Fails hard.
developer_id_sign() {
    identity="${ICA_SIGN_IDENTITY:-$(developer_id_listing | awk '{ print $2; exit }')}"
    if [ -z "$identity" ]; then
        echo "error: no Developer ID Application identity in the keychain." >&2
        echo "       Create one in Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application." >&2
        exit 1
    fi
    ent="$(mktemp)"
    trap 'rm -f "$ent" "$ent.decoded"' EXIT
    cp "$root/signing/ICAViewer.release.entitlements" "$ent"
    if [ -n "${ICA_RELEASE_PROFILE:-}" ]; then
        [ -f "$ICA_RELEASE_PROFILE" ] || { echo "error: ICA_RELEASE_PROFILE not found: $ICA_RELEASE_PROFILE" >&2; exit 1; }
        security cms -D -i "$ICA_RELEASE_PROFILE" >"$ent.decoded" 2>/dev/null || { echo "error: cannot decode $ICA_RELEASE_PROFILE" >&2; exit 1; }
        team="$(plutil -extract TeamIdentifier.0 raw -o - "$ent.decoded" 2>/dev/null || true)"
        [ -n "$team" ] || { echo "error: no team identifier in $ICA_RELEASE_PROFILE" >&2; exit 1; }
        if plutil -extract ProvisionedDevices raw -o - "$ent.decoded" >/dev/null 2>&1; then
            echo "error: $ICA_RELEASE_PROFILE is a device-bound profile; use a Developer ID profile" >&2
            exit 1
        fi
        cp "$ICA_RELEASE_PROFILE" "$app/Contents/embedded.provisionprofile"
        cat >"$ent" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.application-identifier</key><string>$team.$bundle_id</string>
    <key>com.apple.developer.team-identifier</key><string>$team</string>
    <key>keychain-access-groups</key><array><string>$team.$bundle_id</string></array>
</dict>
</plist>
ENT
    fi
    # Inside-out: nested code first, then the bundle (the entitlements belong to the main bundle only).
    find "$app/Contents" \( -path '*/Frameworks/*' -o -path '*/PlugIns/*' -o -path '*/XPCServices/*' \) \
        \( -name '*.dylib' -o -name '*.framework' -o -name '*.xpc' -o -name '*.appex' \) -prune -print |
        while IFS= read -r nested; do
            codesign --force --options runtime --timestamp --sign "$identity" "$nested"
        done
    codesign --force --options runtime --timestamp --entitlements "$ent" --sign "$identity" "$app" ||
        { echo "error: Developer ID signing failed" >&2; exit 1; }
    echo "signed with Developer ID ($identity), hardened runtime${ICA_RELEASE_PROFILE:+, profile $ICA_RELEASE_PROFILE}" >&2
}
adhoc() {
    echo "note: $1; signing ad-hoc (saved secrets use the app-enforced Touch ID check)" >&2
    codesign --force --deep --sign - "$app" >/dev/null 2>&1 || echo "warning: ad-hoc signing failed" >&2
}
if [ "${ICA_SIGN:-}" = adhoc ]; then
    adhoc "ICA_SIGN=adhoc"
elif [ "${ICA_SIGN:-}" = developer-id ]; then
    developer_id_sign
elif [ ! -f "$profile" ]; then
    adhoc "no provisioning profile (run scripts/fetch-profile.sh)"
else
    decoded="$(mktemp)"
    trap 'rm -f "$decoded" "$decoded.ent"' EXIT
    security cms -D -i "$profile" >"$decoded" 2>/dev/null
    team="$(plutil -extract TeamIdentifier.0 raw -o - "$decoded" 2>/dev/null || true)"
    expires="$(plutil -extract ExpirationDate raw -o - "$decoded" 2>/dev/null || true)"
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    identity="${ICA_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development/ { print $2; exit }')}"
    if [ -z "$team" ]; then
        adhoc "cannot read the provisioning profile"
    elif [ -n "$expires" ] && [ "$expires" \< "$now" ]; then
        adhoc "the provisioning profile expired on $expires (run scripts/fetch-profile.sh)"
    elif [ -z "$identity" ]; then
        adhoc "no Apple Development signing identity in the keychain"
    else
        cp "$profile" "$app/Contents/embedded.provisionprofile"
        cat >"$decoded.ent" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.application-identifier</key><string>$team.$bundle_id</string>
    <key>com.apple.developer.team-identifier</key><string>$team</string>
    <key>keychain-access-groups</key><array><string>$team.$bundle_id</string></array>
</dict>
</plist>
ENT
        if codesign --force --options runtime --timestamp=none --entitlements "$decoded.ent" --sign "$identity" "$app" >/dev/null 2>&1; then
            echo "signed with the development identity for team $team (profile expires $expires)" >&2
        else
            rm -f "$app/Contents/embedded.provisionprofile"
            adhoc "codesign with the development identity failed"
        fi
    fi
fi
echo "$app"
