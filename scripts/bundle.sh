#!/bin/sh
# Builds ICAViewer and wraps the executable into ICAViewer.app (bundle identity, Info.plist,
# ad-hoc signature) so it runs as a regular app: Dock icon, AX application, window switchers.
# Usage: scripts/bundle.sh [release|debug]   → .build/ICAViewer.app (release by default: the
# Thinwire pixel loops are far too slow unoptimised for a session that repaints ~20 times a second)
set -eu
config="${1:-release}"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
swift build -c "$config" --product ICAViewer
bin="$(swift build -c "$config" --show-bin-path)/ICAViewer"
app="$root/.build/ICAViewer.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/ICAViewer"
cat > "$app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.alttab.ICAViewer</string>
    <key>CFBundleName</key><string>ICAViewer</string>
    <key>CFBundleDisplayName</key><string>ICA Viewer</string>
    <key>CFBundleExecutable</key><string>ICAViewer</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
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
adhoc() {
    echo "note: $1; signing ad-hoc (saved secrets use the app-enforced Touch ID check)" >&2
    codesign --force --sign - "$app" >/dev/null 2>&1 || echo "warning: ad-hoc signing failed" >&2
}
if [ ! -f "$profile" ]; then
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
