#!/bin/sh
# Compiles assets/icon/AppIcon.icon (the source; edit it in Icon Composer) into the checked-in
# outputs, so a normal build needs no Xcode:
#   assets/icon/Assets.car     Liquid Glass icon for macOS 26+ (default, dark, clear, tinted)
#   assets/icon/AppIcon.icns   fallback for macOS 14/15, all sizes 16..512@2x
#   assets/icon/appearances.png  preview of the six macOS appearances
# Needs Xcode 26+ (actool, Icon Composer's ictool). Run it after every change to AppIcon.icon.
set -eu
cd "$(dirname "$0")/.."
src="$PWD/assets/icon/AppIcon.icon"; out="$PWD/assets/icon"
ictool="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

xcrun actool "$src" --compile "$tmp" --platform macosx --minimum-deployment-target 14.0 \
    --app-icon AppIcon --output-partial-info-plist "$tmp/partial.plist" >/dev/null
cp "$tmp/Assets.car" "$out/Assets.car"

render() { "$ictool" "$src" --export-image --output-file "$2" --platform macOS --rendition "$1" \
    --width "$3" --height "$3" --scale "$4" --tint-color 0.6 --tint-strength 0.7 >/dev/null; }
mkdir "$tmp/AppIcon.iconset"
for s in 16 32 128 256 512; do
    render Default "$tmp/AppIcon.iconset/icon_${s}x${s}.png" $s 1
    render Default "$tmp/AppIcon.iconset/icon_${s}x${s}@2x.png" $s 2
done
iconutil -c icns "$tmp/AppIcon.iconset" -o "$out/AppIcon.icns"

for r in Default Dark ClearLight ClearDark TintedLight TintedDark; do render $r "$tmp/$r.png" 256 1; done
if command -v magick >/dev/null; then
    magick \( "$tmp/Default.png" "$tmp/Dark.png" "$tmp/ClearLight.png" "$tmp/ClearDark.png" \
        "$tmp/TintedLight.png" "$tmp/TintedDark.png" +append \) -background '#808080' -flatten \
        "$out/appearances.png"
fi
echo "ok: $out/Assets.car, $out/AppIcon.icns"
