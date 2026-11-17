#!/bin/bash
# Rebuilds the user manual's screenshots and checks the manual. Run it for every release, before make-dmg.sh.
#
#   scripts/manual/build.sh [options]
#     --bundle     build .build/ICAViewer.app first (scripts/bundle.sh); default: use the existing bundle
#     --app PATH   the app bundle to photograph (default .build/ICAViewer.app)
#     --from DIR   use the results of an earlier VM run (/tmp/icashot/macvm/<run>) instead of starting one
#     --no-shots   skip the VM run; only stamp the version and run the checks on the images already in manual/images
#     --pdf        also render manual/ICAViewer-Manual-<version>.pdf (pandoc + Google Chrome; for the GitHub release)
#
# What it does:
#   1. Starts scripts/manual/shots.sh in the macOS test VM through scripts/macvm/exec.sh (queue, one clone, nothing
#      on this Mac's screen) with the lab user labuser3 (.session/lab-user3.env, see scripts/macvm/labuser.sh).
#   2. Copies the PNGs it saved to manual/images/<name>.png, scaled down to at most 1100 px wide and compressed
#      (pngquant when installed), after wiping the old ones. A screen the script could not capture fails the build,
#      except a "soft" one (the large-copy progress window), which keeps its previous image with a warning.
#   3. Checks that every image the Markdown refers to exists and that every image file is referenced.
#   4. Runs scripts/shotcheck.swift on every image (OCR for forbidden words from .shotcheck-forbidden, metadata strip).
#   5. Runs the publish audit's pattern list (read from ../tools/ica-publish/publish.sh) and the forbidden words over
#      manual/ and over the version-stamped text; checks the total size of the images (under 15 MB).
#   6. Stamps the version from VERSION into manual/README.md (<!-- version -->...<!-- /version -->).
# Exit status: 0 only when every check passes.
set -eu
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
manual="$root/manual"
images="$manual/images"
app=.build/ICAViewer.app
bundle=0 shots=1 pdf=0 from=
while [ $# -gt 0 ]; do
    case $1 in
        --bundle) bundle=1 ;;
        --app) shift; app=$1 ;;
        --no-shots) shots=0 ;;
        --from) shift; from=$1 ;;
        --pdf) pdf=1 ;;
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
        *) echo "unknown option $1" >&2; exit 2 ;;
    esac
    shift
done
version=$(tr -d ' \n\r' <VERSION)
fail=0
say() { echo "[manual] $*"; }
bad() { echo "[manual] FAIL: $*" >&2; fail=1; }

# ---------------------------------------------------------------- 1 + 2: screenshots
if [ $shots = 1 ]; then
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    if [ -n "$from" ]; then out=$from; else
    [ $bundle = 1 ] && scripts/bundle.sh
    [ -d "$app" ] || { echo "no $app (use --bundle)" >&2; exit 1; }
    [ -f .session/lab-user3.env ] || { echo "no .session/lab-user3.env (scripts/macvm/labuser.sh 3)" >&2; exit 1; }
    python3 -I scripts/manual/sample-image.py "$work/sample.png"
    run=manual-$(date +%Y%m%d-%H%M%S)
    say "VM run $run (waits for the shared VM queue)"
    MACVM_RUN=$run scripts/macvm/exec.sh "$app" scripts/manual/shots.sh .session/lab-user3.env "$work/sample.png" || say "the VM run reported failures; checking what it saved"
    out=/tmp/icashot/macvm/$run
    fi
    [ -s "$out/manual-shots.txt" ] || { echo "no $out/manual-shots.txt: the VM run did not reach the screens" >&2; exit 1; }
    if grep -q '^MISS' "$out/manual-shots.txt"; then
        bad "screens not captured: $(grep '^MISS' "$out/manual-shots.txt" | cut -d' ' -f2 | paste -sd' ' -); see $out/results.txt, $out/ax-*.txt"
        say "the existing images in manual/images stay as they are"
    else
        mkdir -p "$images" "$work/old"
        cp "$images"/*.png "$work/old/" 2>/dev/null || true
        rm -f "$images"/*.png
        for f in "$out"/manual-*.png; do
            name=$(basename "$f" .png); name=${name#manual-}
            cp "$f" "$images/$name.png"
            w=$(sips -g pixelWidth "$images/$name.png" | awk '/pixelWidth/ {print $2}')
            [ "$w" -gt 1100 ] && sips --resampleWidth 1100 "$images/$name.png" >/dev/null
        done
        # A soft miss (a screen that depends on lab speed, such as the large-copy progress window) keeps its
        # previous image, with a warning: look at it before you release.
        for name in $(grep '^SOFT' "$out/manual-shots.txt" | cut -d' ' -f2); do
            [ -f "$images/$name.png" ] && continue
            if [ -f "$work/old/$name.png" ]; then cp "$work/old/$name.png" "$images/$name.png"; say "WARNING: $name.png was not captured; the previous image is kept"
            else bad "$name was not captured and there is no previous image"; fi
        done
        if command -v pngquant >/dev/null; then
            pngquant --force --skip-if-larger --quality 70-95 --ext .png "$images"/*.png || true
        else
            say "pngquant not installed (brew install pngquant); the images are only scaled"
        fi
        say "$(ls "$images" | wc -l | tr -d ' ') images saved"
    fi
fi

# ---------------------------------------------------------------- 6: version stamp
sed -i '' "s|<!-- version -->.*<!-- /version -->|<!-- version -->$version<!-- /version -->|" "$manual/README.md"
grep -q "<!-- version -->$version<!-- /version -->" "$manual/README.md" || bad "manual/README.md has no version marker"

# ---------------------------------------------------------------- 3: images referenced <-> present
refs=$(grep -rhoE '\(images/[^) ]+\.png\)|src="images/[^"]+\.png"' "$manual"/*.md | sed -E 's/^\(//; s/\)$//; s/^src="//; s/"$//' | sed 's|^images/||' | sort -u)
files=$(cd "$images" 2>/dev/null && ls *.png 2>/dev/null | sort -u || true)
for r in $refs; do echo "$files" | grep -qx "$r" || bad "referenced but missing: images/$r"; done
for f in $files; do echo "$refs" | grep -qx "$f" || bad "image file never referenced: images/$f"; done
say "$(echo "$refs" | grep -c .) image references, $(echo "$files" | grep -c .) image files"
# Every image needs alt text: ![](...) is not allowed.
grep -n '!\[\](' "$manual"/*.md >/dev/null 2>&1 && bad "an image without alt text"
# Local links between chapters resolve.
for f in "$manual"/*.md; do
    for l in $(grep -oE '\]\([^)#: ]+\.md' "$f" | sed 's/^](//' | sort -u); do
        [ -f "$manual/$l" ] || bad "$(basename "$f") links to missing $l"
    done
done

# ---------------------------------------------------------------- size
kb=$(du -sk "$images" 2>/dev/null | cut -f1)
say "images: ${kb:-0} KB"
[ "${kb:-0}" -lt 15360 ] || bad "images are over 15 MB"

# ---------------------------------------------------------------- 4: screenshots checked for secrets
if [ -n "$files" ]; then
    if [ ! -x /tmp/icashotcheck ] || [ scripts/shotcheck.swift -nt /tmp/icashotcheck ]; then swiftc -O scripts/shotcheck.swift -o /tmp/icashotcheck 2>/dev/null || bad "cannot build shotcheck"; fi
    if [ -x /tmp/icashotcheck ]; then
        (cd "$images" && ICA_SHOT_ANY_CORNERS=1 /tmp/icashotcheck strip ./*.png >/dev/null)
        if ICA_SHOT_ANY_CORNERS=1 /tmp/icashotcheck check "$images"/*.png >/tmp/manual-shotcheck.txt 2>&1; then say "shotcheck: no forbidden words in the images"
        else bad "shotcheck found a problem; read /tmp/manual-shotcheck.txt"; fi
        grep -q WARNING /tmp/manual-shotcheck.txt && say "warning: .shotcheck-forbidden is missing, so the OCR check had no word list"
    fi
fi

# ---------------------------------------------------------------- 5: text audit
pub="$root/../tools/ica-publish/publish.sh"
if [ -f "$pub" ]; then
    pattern=$(sed -n "s/^pattern='\(.*\)'\$/\1/p" "$pub")
    if [ -n "$pattern" ]; then
        n=$(grep -rE --include="*.md" --include="*.sh" --include="*.py" --include="*.css" "$pattern" "$manual" "$root/RELEASING.md" "$root/scripts/manual" 2>/dev/null | grep -v -E '/Users/(someone|emuster|Shared|<name>)' | grep -c . || true)
        [ "$n" = 0 ] && say "publish audit pattern: 0 hits in the manual" || bad "publish audit pattern: $n hit(s) in the manual (run the grep by hand; do not paste the lines anywhere public)"
    else say "no pattern line found in publish.sh; audit text skipped"; fi
else say "publish.sh not found; audit text skipped"; fi
if [ -f "$root/.shotcheck-forbidden" ]; then
    n=$(grep -rilE --include="*.md" --include="*.sh" --include="*.py" --include="*.css" -f <(grep -v -E '^\s*(#|$)' "$root/.shotcheck-forbidden") "$manual" "$root/RELEASING.md" "$root/scripts/manual" 2>/dev/null | grep -c . || true)
    [ "$n" = 0 ] && say "forbidden words: none in the manual text" || bad "forbidden words in $n file(s); find them with grep -rilE --include="*.md" --include="*.sh" --include="*.py" --include="*.css" -f .shotcheck-forbidden manual"
fi

# ---------------------------------------------------------------- optional PDF
if [ $pdf = 1 ] && [ $fail = 0 ]; then scripts/manual/pdf.sh || bad "PDF failed"; fi

[ $fail = 0 ] && say "OK (version $version)" || { say "FAILED"; exit 1; }
