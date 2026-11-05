#!/bin/sh
# README screenshots of the demo windows (example data, no network), plus the privacy checks.
#
#   scripts/screenshots.sh                 capture login, launcher, settings, hud, gaveup into
#                                          assets/screenshots/<name>.png, then check them
#   scripts/screenshots.sh check <png>...  strips metadata chunks (tEXt, iTXt, zTXt, eXIf, tIME), then OCR +
#                                          corner checks (also for live captures)
#   scripts/screenshots.sh composite <out.png> <window.png> [<hud.png>...]
#                                          window on a flat #E5E5EA background with 48 px padding, other
#                                          images centred over it (live remote window + HUD); then checks it
#
# Needs .build/ICAViewer.app (scripts/bundle.sh) and Screen Recording permission for the terminal.
# Refuses to run while an ICAViewer is running. The demo app opens real windows on the main screen and
# is quit again after each capture. ICAVIEWER_SCREENSHOT=1 censors resource names in live captures too.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
out="assets/screenshots"
names="login launcher settings hud gaveup"

helper="$root/.build/shotcheck"
if [ ! -x "$helper" ] || [ scripts/shotcheck.swift -nt "$helper" ]; then
    mkdir -p "$root/.build"
    swiftc -O scripts/shotcheck.swift -o "$helper"
fi

case "${1:-demo}" in
check)
    shift
    "$helper" strip "$@"
    exec "$helper" check "$@"
    ;;
composite)
    [ $# -ge 3 ] || { echo "usage: $0 composite <out.png> <window.png> [<hud.png>...]" >&2; exit 2; }
    shift
    target="$1"
    "$helper" composite "$@"
    "$helper" strip "$target"
    exec "$helper" check "$target"
    ;;
demo) ;;
*)
    echo "usage: $0 [demo | check <png>... | composite <out.png> <window.png> [<hud.png>...]]" >&2
    exit 2
    ;;
esac

app="$root/.build/ICAViewer.app/Contents/MacOS/ICAViewer"
[ -x "$app" ] || { echo "$app not found; run scripts/bundle.sh first" >&2; exit 1; }
if pgrep -x ICAViewer >/dev/null; then
    echo "an ICAViewer is running; quit it first" >&2
    exit 1
fi

mkdir -p "$out"
log="$(mktemp -t ica-demo)"
pid=""
cleanup() {
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    rm -f "$log"
}
trap cleanup EXIT INT TERM

for name in $names; do
    : > "$log"
    ICAVIEWER_DEMO=1 ICAVIEWER_DEMO_SHOW="$name" ICAVIEWER_SCREENSHOT=1 \
        "$app" -AppleLanguages "(en)" 2> "$log" &
    pid=$!
    id=""
    n=0
    while [ $n -lt 100 ]; do
        id="$(sed -n "s/.*demo window $name id \([0-9][0-9]*\)$/\1/p" "$log" | tail -n 1)"
        [ -n "$id" ] && break
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.2
        n=$((n + 1))
    done
    if [ -z "$id" ] || [ "$id" -le 0 ]; then
        echo "no window id for $name; log:" >&2
        cat "$log" >&2
        exit 1
    fi
    # -l window id, -o no shadow, -x no sound; PNG keeps the alpha channel; the cursor is not captured.
    screencapture -l "$id" -o -x "$out/$name.png"
    [ -s "$out/$name.png" ] || { echo "screencapture produced nothing for $name (Screen Recording permission?)" >&2; exit 1; }
    echo "captured $out/$name.png (window $id)"
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    pid=""
done

"$helper" strip "$out"/login.png "$out"/launcher.png "$out"/settings.png "$out"/hud.png "$out"/gaveup.png
"$helper" check "$out"/login.png "$out"/launcher.png "$out"/settings.png "$out"/hud.png "$out"/gaveup.png
