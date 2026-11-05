#!/bin/sh
# Fetches the macOS development provisioning profile for local.alttab.ICAViewer (Keychain Sharing,
# needed for Keychain-enforced Touch ID protection) into signing/ICAViewer.provisionprofile (0600,
# git-ignored). Needs an Apple account in Xcode (Settings > Accounts) for team TEAMID0000; the first
# run registers the App ID and this Mac with that account.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root/signing"
command -v xcodegen >/dev/null && xcodegen generate --quiet
xcodebuild -project ICAViewerSigning.xcodeproj -scheme ICAViewerSigning -configuration Debug \
    -derivedDataPath DerivedData -allowProvisioningUpdates build >/tmp/ica-fetch-profile.log 2>&1 || {
    grep -E "error:" /tmp/ica-fetch-profile.log >&2
    echo "fetch-profile: xcodebuild failed (full log: /tmp/ica-fetch-profile.log)" >&2
    exit 1
}
# The profile Xcode embedded into the stub app is the one for our bundle ID.
src="DerivedData/Build/Products/Debug/ICAViewerSigning.app/Contents/embedded.provisionprofile"
[ -f "$src" ] || { echo "fetch-profile: no embedded profile in the stub build" >&2; exit 1; }
install -m 600 "$src" "$root/signing/ICAViewer.provisionprofile"
security cms -D -i "$root/signing/ICAViewer.provisionprofile" 2>/dev/null \
    | plutil -extract Entitlements xml1 -o - - | grep -A3 -E "application-identifier|keychain-access-groups" | grep string
echo "profile: $root/signing/ICAViewer.provisionprofile"
