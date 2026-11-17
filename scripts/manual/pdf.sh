#!/bin/bash
# Renders manual/ICAViewer-Manual-<version>.pdf from the Markdown chapters: pandoc (Markdown to one HTML file
# with the images embedded), then headless Google Chrome (HTML to PDF). No LaTeX. Needs: brew install pandoc.
# Called by build.sh --pdf; can be run alone after a build.
set -eu
root="$(cd "$(dirname "$0")/../.." && pwd)"
manual="$root/manual"
version=$(tr -d ' \n\r' <"$root/VERSION")
command -v pandoc >/dev/null || { echo "pandoc not found (brew install pandoc)" >&2; exit 1; }
chrome="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
[ -x "$chrome" ] || { echo "Google Chrome not found (set CHROME=...)" >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# One document: README first, then the numbered chapters. Links between chapter files become links inside it.
{
    for f in "$manual/README.md" "$manual"/[0-9][0-9]-*.md; do
        id=$(basename "$f" .md)
        echo "<a id=\"chapter-$id\"></a>"; echo
        cat "$f"; echo; echo
    done
} | sed -E 's/\]\(([0-9]{2}-[a-z0-9-]+)\.md#([^)]+)\)/](#\2)/g; s/\]\(([0-9]{2}-[a-z0-9-]+)\.md\)/](#chapter-\1)/g; s/\]\(README\.md\)/](#chapter-README)/g' \
  | sed -E "s|<!-- version -->.*<!-- /version -->|$version|" >"$work/manual.md"

cd "$manual"   # images/ resolves from here
pandoc -f gfm -t html5 --standalone --embed-resources --metadata "pagetitle=ICAViewer User Manual" \
    --metadata "lang=en" --css "$root/scripts/manual/manual.css" "$work/manual.md" -o "$work/manual.html"
out="$manual/ICAViewer-Manual-$version.pdf"
"$chrome" --headless=new --disable-gpu --no-pdf-header-footer --print-to-pdf="$out" "file://$work/manual.html" >/dev/null 2>&1
[ -s "$out" ] || { echo "Chrome produced no PDF" >&2; exit 1; }
echo "[manual] $out ($(du -k "$out" | cut -f1) KB)"
