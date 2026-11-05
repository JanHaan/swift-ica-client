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
codesign --force --sign - "$app" >/dev/null 2>&1 || echo "warning: ad-hoc signing failed" >&2
echo "$app"
