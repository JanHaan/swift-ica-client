#!/bin/sh
# Builds the template helper app for per-app Dock identity (docs/99 phase 1 spike): ICAViewerHelper.app.
# The host copies it per remote app, relabels it (CFBundleName, CFBundleIdentifier, icon) and re-signs
# the copy ad-hoc at runtime (AppHostKit/HelperBundleGenerator.swift). Not embedded in ICAViewer.app yet
# (phase 3); scripts/bundle.sh is unchanged.
# Usage: scripts/bundle-helper.sh [release|debug]   → .build/ICAViewerHelper.app (release by default)
# Environment (all optional):
#   ICA_BUNDLE_OUT=<dir>      directory to put ICAViewerHelper.app in (default .build)
#   ICA_SIGN_IDENTITY=<name>  sign the template with this identity (hardened runtime, secure timestamp),
#                             as a release build would; default: ad-hoc with hardened runtime
#   ICA_VERSION=<x.y>         CFBundleShortVersionString (default 0.1)
#   ICA_SWIFT_FLAGS=<...>     extra swift build flags (word-split), e.g. "--arch arm64 --arch x86_64"
set -eu
config="${1:-release}"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
version="${ICA_VERSION:-0.1}"
# shellcheck disable=SC2086
swift build -c "$config" --product ICAViewerHelper ${ICA_SWIFT_FLAGS:-}
# shellcheck disable=SC2086
bin="$(swift build -c "$config" --show-bin-path ${ICA_SWIFT_FLAGS:-})/ICAViewerHelper"
out="${ICA_BUNDLE_OUT:-$root/.build}"
mkdir -p "$out"
app="$(cd "$out" && pwd)/ICAViewerHelper.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/ICAViewerHelper"
# LSMultipleInstancesProhibited: one process per generated app (docs/99 §5). No LSUIElement: helpers
# are regular apps with a Dock tile and a Cmd-Tab entry.
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.alttab.ICAViewer.helper</string>
    <key>CFBundleName</key><string>ICAViewerHelper</string>
    <key>CFBundleExecutable</key><string>ICAViewerHelper</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSMultipleInstancesProhibited</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
</dict>
</plist>
PLIST
if [ -n "${ICA_SIGN_IDENTITY:-}" ]; then
    codesign --force --options runtime --timestamp --sign "$ICA_SIGN_IDENTITY" "$app"
    echo "signed with $ICA_SIGN_IDENTITY, hardened runtime" >&2
else
    codesign --force --options runtime --sign - "$app"
fi
codesign --verify --strict "$app"
echo "$app"
