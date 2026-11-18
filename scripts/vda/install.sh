#!/bin/bash
# Copies lab-side helper scripts to C:\Users\Public on the lab VDA through the lab host's guest agent (icalab.sh ga).
# usage: scripts/vda/install.sh [file …]   (default: every scripts/vda/*.ps1)
set -eu
here=$(cd "$(dirname "$0")" && pwd)
[ $# -gt 0 ] || set -- "$here"/*.ps1
labssh() { ssh -i ~/.ssh/<lab-key> -o BatchMode=yes <user>@<lab-host> "$@"; }
for f in "$@"; do
    name=$(basename "$f")
    printf "[IO.File]::WriteAllBytes('C:\\\\Users\\\\Public\\\\%s',[Convert]::FromBase64String('%s'))\n(Get-Item 'C:\\\\Users\\\\Public\\\\%s').Length\n" \
        "$name" "$(base64 <"$f" | tr -d '\n')" "$name" |
        labssh "cat > /tmp/vda-install-$name && /home/<user>/src/icalab/icalab.sh ga icalab-t1-vda /tmp/vda-install-$name; rm -f /tmp/vda-install-$name" |
        tr -d '\r' | sed "s/^/$name: bytes /"
done
