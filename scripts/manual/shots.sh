#!/bin/bash
# Guest script: drives ICA Viewer in the macOS test VM and saves the user manual's screenshots.
# Not meant to run by hand; scripts/manual/build.sh starts it through scripts/macvm/exec.sh:
#   scripts/manual/build.sh            (builds and runs everything)
# Files passed in: lab-user3.env (credentials, never printed) and sample.png (a picture to paste).
# Output in $OUT: manual-<name>.png (one per image the manual uses) and manual-shots.txt (OK/MISS per name).
# Controls are found by AX role, title, id or placeholder, never by coordinates. A screen that does not
# open is logged as MISS; build.sh then fails because the Markdown references an image that does not exist.
set -u
. ~/test/lib.sh
SCEN=manual
for f in "$FILES"/lab-user*.env; do [ -f "$f" ] && { [ "$f" = "$FILES/lab-user.env" ] || cp "$f" "$FILES/lab-user.env"; }; break; done
STORE=${STORE:-http://10.77.0.11}
HOST=${STORE#*://}; HOST=${HOST%%/*}
V=ICA\ Viewer
LOG=$HOME/Library/Logs/ICAViewer/ICAViewer.log
STDOUT=$OUT/viewer-stdout.log
LIST=$OUT/manual-shots.txt; : >"$LIST"

win() { ax cgwindows "$1" 2>/dev/null | awk -F'\t' -v o="$1" -v t="$2" '$2 == o && (t == "" || index($5, t)) {print; exit}'; }
has_win() { [ -n "$(win "$1" "$2")" ]; }
rows() { ax count "$V" role=AXRow 2>/dev/null || echo 0; }
soft() { echo "SOFT $1" >>"$LIST"; note "soft miss $1: $2"; }
miss() { echo "MISS $1" >>"$LIST"; result FAIL "$1" "not captured${2:+: $2}"; }
ok() { echo "OK $1" >>"$LIST"; note "manual-$1.png"; }
snap_id() { # snap_id <window id> <name>
    guirun /usr/sbin/screencapture -x -o -l "$1" "$OUT/manual-$2.png" 2>/dev/null && [ -s "$OUT/manual-$2.png" ] && ok "$2" || miss "$2"
}
snap() { # snap <owner> <title-substring> <name>: one window by CGWindow id
    id=$(win "$1" "$2" | cut -f1); [ -n "$id" ] || { miss "$3" "no window '$2' of $1"; return 1; }
    snap_id "$id" "$3"
}
snap_untitled() { # an untitled window of an owner (alerts, About panels): normal layer first, then any layer, at least 100 pt tall
    for flag in "" "--any-layer"; do
        id=$(ax cgwindows $flag "$1" | awk -F'\t' -v o="$1" '$2 == o && $5 == "" {split($4, a, /[x+]/); if (a[2] >= 100) {print $1; exit}}')
        [ -n "$id" ] && break
    done
    [ -n "$id" ] || { miss "$2" "no untitled window of $1"; return 1; }
    snap_id "$id" "$2"
}
snap_rect() { # snap_rect <name> <x> <y> <w> <h> (points)
    guirun /usr/sbin/screencapture -x -R "$2,$3,$4,$5" "$OUT/manual-$1.png" 2>/dev/null && [ -s "$OUT/manual-$1.png" ] && ok "$1" || miss "$1"
}
snap_screen() { guirun /usr/sbin/screencapture -x "$OUT/manual-$1.png" 2>/dev/null && [ -s "$OUT/manual-$1.png" ] && ok "$1" || miss "$1"; }
tree() { ax tree "$1" --depth "${3:-12}" >"$OUT/ax-$2.txt" 2>&1; }
appearance_light() { # light mode (the golden image is light; no Apple event to System Events, which would wait for a prompt)
    if guirun defaults read -g AppleInterfaceStyle >/dev/null 2>&1; then guirun defaults delete -g AppleInterfaceStyle; sleep 2; fi
}
launch() { # launch <search text> <helper app> <window title> [seconds]: opens the launcher (shortcut, retried) and starts an app
    for try in 1 2 3; do
        ax wait "$V" placeholder=Search --timeout 5 >/dev/null 2>&1 && break
        ax key ctrl+alt+cmd+l >/dev/null; sleep 3
    done
    ax focus "$V" placeholder=Search >/dev/null; ax set "$V" placeholder=Search --value "" >/dev/null
    ax type "$1" >/dev/null; sleep 1; ax key return >/dev/null
    wait_for "${4:-90}" has_win "$2" "$3"
}
close_finder() { # AX, not osascript: an Apple event to Finder waits for an Automation prompt nobody can click
    ax activate Finder >/dev/null 2>&1; sleep 1; ax key cmd+alt+w >/dev/null 2>&1; sleep 1
}
focus_remote() { ax raise "$1" role=AXWindow title~"$2" >/dev/null && ax click "$1" role=AXWindow title~"$2" >/dev/null; sleep 1; }

appearance_light
# A clean desktop: no Terminal window, no widgets, no notification banners from the stock apps in the image.
pkill -x Terminal 2>/dev/null
guirun defaults write com.apple.WindowManager StandardHideWidgets -bool true 2>/dev/null
guirun defaults write com.apple.WindowManager StandardHideWidgets -bool true 2>/dev/null
guirun defaults -currentHost write com.apple.notificationcenterui doNotDisturb -boolean true 2>/dev/null
guirun killall Dock 2>/dev/null; sleep 4
clean_notifications() { # dismiss banners (a stock-app notice stays on screen otherwise)
    for i in 1 2 3; do ax press NotificationCenter role=AXButton title=Close >/dev/null 2>&1 || ax press NotificationCenter subrole=AXCloseButton >/dev/null 2>&1 || break; sleep 1; done
    guirun killall usernoted NotificationCenter 2>/dev/null; sleep 2
}
clean_notifications
nc -z -G 4 "$HOST" 80 || { echo "lab $HOST unreachable"; echo 1 >"$OUT/.rc"; exit 1; }
[ -f "$FILES/lab-user.env" ] || { echo "no lab-user*.env"; echo 1 >"$OUT/.rc"; exit 1; }

# ------------------------------------------------------------ illustrations (demo mode, example data)
# The lab has no gateway with nFactor and cannot cut the network on demand, so these three screens come from
# the app's demo mode (example host, example user, made-up secret). The manual labels them as illustrations.
for w in login hud gaveup; do
    stop_viewer; : >"$STDOUT"
    start_viewer ICAVIEWER_DEMO=1 ICAVIEWER_DEMO_SHOW=$w
    if wait_for 25 grep -q "demo window $w id" "$STDOUT"; then
        sleep 1.5
        id=$(sed -n "s/.*demo window $w id \([0-9]*\).*/\1/p" "$STDOUT" | tail -1)
        snap_id "$id" "demo-$w"
    else miss "demo-$w" "no demo window"; fi
done
stop_viewer

# ------------------------------------------------------------ installation: the disk image window
dmg=$HOME/test/dmgstage
rm -rf "$dmg"; mkdir -p "$dmg"
cp -R "$APP" "$dmg/ICAViewer.app"; ln -s /Applications "$dmg/Applications"
printf 'ICAViewer\n\nInstall: drag ICAViewer.app to Applications.\n' >"$dmg/README.txt"
rm -f "$HOME/test/ICAViewer.dmg"
hdiutil create -volname ICAViewer -srcfolder "$dmg" -ov -format UDZO "$HOME/test/ICAViewer.dmg" >/dev/null 2>&1
hdiutil detach /Volumes/ICAViewer -quiet 2>/dev/null
if hdiutil attach "$HOME/test/ICAViewer.dmg" -mountpoint /Volumes/ICAViewer -readonly -quiet 2>/dev/null; then
    guirun open /Volumes/ICAViewer; sleep 3
    sleep 2
    ax drag Finder role=AXWindow --from corner --dx -1100 --dy -420 >/dev/null 2>&1; sleep 2
    snap Finder ICAViewer dmg || snap Finder "" dmg
    close_finder
    hdiutil detach /Volumes/ICAViewer -quiet 2>/dev/null
else miss dmg "hdiutil attach failed"; fi
rm -rf "$dmg" "$HOME/test/ICAViewer.dmg"

# ------------------------------------------------------------ signing in
stop_viewer; defaults delete local.alttab.ICAViewer >/dev/null 2>&1
security delete-internet-password -s "$HOST" >/dev/null 2>&1
start_viewer
if ! ax wait "$V" placeholder~"store address" --timeout 30 >/dev/null; then miss login-address "no Sign In window"; finish; exit 0; fi
sleep 1; snap "$V" "Sign In" login-address
ax focus "$V" placeholder~"store address" >/dev/null; ax type "$STORE" >/dev/null; ax key return >/dev/null
if ax wait "$V" id=username --timeout 30 >/dev/null; then
    sleep 1
    ax focus "$V" id=username >/dev/null; ax type "$(lab_user)" >/dev/null
    ax focus "$V" id=password >/dev/null; ax type "wrong-$RANDOM-pw" >/dev/null   # a wrong password first: the error shot
    ax click "$V" role=AXCheckBox title~"Remember" >/dev/null 2>&1   # AXPress is unsupported on this checkbox
    sleep 1; snap "$V" "Sign In" login-form      # the password shows as dots
    ax press "$V" id=loginBtn >/dev/null
    ax wait "$V" role=AXStaticText value~"incorrect" --timeout 20 >/dev/null
    sleep 1; snap "$V" "Sign In" login-error
    ax focus "$V" id=password >/dev/null; ax key cmd+a >/dev/null; lab_password | ax type --stdin >/dev/null
    ax press "$V" id=loginBtn >/dev/null
else miss login-form "no user name field after $STORE"; fi

wait_for 60 sh -c "[ \$(guirun axrunner count '$V' role=AXRow 2>/dev/null || echo 0) -ge 1 ]"
sleep 1
if ax wait "$V" role=AXSheet --timeout 4 >/dev/null; then ax press "$V" role=AXButton title~"Not Now" >/dev/null; sleep 1; fi
[ "$(rows)" -ge 1 ] || { miss launcher "no launcher after sign-in"; finish; exit 0; }
sleep 1; snap "$V" "ICA Viewer" launcher
ax focus "$V" placeholder=Search >/dev/null; ax type notep >/dev/null; sleep 1
snap "$V" "ICA Viewer" launcher-filter
ax key return >/dev/null

# ------------------------------------------------------------ remote apps
if wait_for 120 has_win Notepad Notepad; then
    sleep 3; focus_remote Notepad Notepad
    ax type "Shopping list" >/dev/null; ax key return >/dev/null; ax type "Coffee, bread, oranges" >/dev/null; sleep 2
    snap Notepad Notepad notepad
else miss notepad "no Notepad window"; fi
launch wordp WordPad WordPad 90 >/dev/null
launch paint Paint Paint 90 >/dev/null
sleep 3
tree Dock dock 5
# Dock strip around the three remote apps' icons (positions from the Dock's AX items); fixed fallback.
minx=99999; maxx=0; dy=0
for n in Notepad WordPad Paint; do
    raw=$(ax attr Dock title="$n" AXPosition 2>/dev/null | sed -n 's/.*x:\([0-9.]*\) y:\([0-9.]*\).*/\1 \2/p')
    echo "dock item $n: $(ax attr Dock title="$n" AXPosition 2>&1 | head -1)" >>"$OUT/checks.log"
    x=$(echo $raw | awk '{print int($1)}'); y=$(echo $raw | awk '{print int($2)}')
    [ -n "$x" ] && [ "$x" -gt 0 ] 2>/dev/null || continue
    [ "$x" -lt "$minx" ] && minx=$x; [ "$x" -gt "$maxx" ] && maxx=$x; dy=$y
done
if [ "$maxx" -gt 0 ]; then snap_rect dock $((minx - 70)) $((dy + 4)) $((maxx - minx + 210)) 92
else snap_rect dock 1340 980 520 100; fi
focus_remote Notepad Notepad
snap_rect menubar 0 0 760 36
ax press Notepad role=AXMenuBarItem title=Session >/dev/null; sleep 1
snap_rect menu-session 0 0 760 260
ax key escape >/dev/null; sleep 1
clean_notifications
ax press "$V" subrole=AXMenuExtra desc="ICA Viewer" >/dev/null 2>&1
sleep 1
snap_rect status-menu 1320 0 600 420
ax key escape >/dev/null; sleep 1
tree "$V" status-item 6
clean_notifications; snap_rect desktop 0 140 1920 940   # below the menu bar: a stock-app banner sits at the top right
# Cmd-Tab between the apps is shown in the text; the window list of the Mission Control style is not captured.

# ------------------------------------------------------------ clipboard
printf 'Hello from the Mac. This text was copied on the Mac and pasted into Windows.' | guirun pbcopy
focus_remote Notepad Notepad
ax key ctrl+a delete >/dev/null
ax key ctrl+v >/dev/null; sleep 2
snap Notepad Notepad clipboard-text
ax key ctrl+a delete >/dev/null; sleep 1
if has_win Paint Paint && [ -f "$FILES/sample.png" ]; then
    guirun osascript -e "set the clipboard to (read (POSIX file \"$FILES/sample.png\") as «class PNGf»)"
    focus_remote Paint Paint; ax key ctrl+v >/dev/null; sleep 3
    snap Paint Paint clipboard-image
else miss clipboard-image "no Paint or sample.png"; fi
# Files: Finder -> File Explorer.
if launch "file expl" "File Explorer" "" 60 && wait_for 30 sh -c "guirun axrunner cgwindows 'File Explorer' | grep -q ."; then
    sleep 2; ax raise "File Explorer" role=AXWindow >/dev/null; sleep 1
    ax key ctrl+l >/dev/null; sleep 1; ax type "%TEMP%" >/dev/null; ax key return >/dev/null
    wait_for 15 sh -c "guirun axrunner cgwindows 'File Explorer' | cut -f5 | grep -qx Temp"
    x=$HOME/test/xfer; rm -rf "$x"; mkdir -p "$x/back"
    printf 'Shopping list\nCoffee, bread, oranges\n' >"$x/Shopping list.txt"
    guirun open -R "$x/Shopping list.txt"; sleep 2
    ax key cmd+c >/dev/null; sleep 6
    ax raise "File Explorer" role=AXWindow >/dev/null; ax click "File Explorer" role=AXWindow >/dev/null; sleep 1
    ax key ctrl+v >/dev/null; sleep 4
    snap "File Explorer" "" clipboard-files
    close_finder
else miss clipboard-files "File Explorer did not open"; fi

x=$HOME/test/xfer
# A copy of more than 50 MB from the session is fetched in the background, with a progress window. It goes last
# because the transfer to the session is slow when the lab impairs the network; a miss is soft (the old image stays).
big_copy() {
    has_win "File Explorer" "" || ax cgwindows "File Explorer" | grep -q . || { soft clipboard-progress "no File Explorer"; return; }
        head -c 60000000 /dev/urandom >"$x/Training video.bin"
        guirun open -R "$x/Training video.bin"; sleep 2
        ax key cmd+c >/dev/null; sleep 6
        n=$(($(wc -l <"$LOG") + 1))
        for try in 1 2 3; do   # the paste is retried when Explorer did not start reading
            ax raise "File Explorer" role=AXWindow >/dev/null; ax click "File Explorer" role=AXWindow >/dev/null; sleep 2
            ax key ctrl+v >/dev/null
            wait_for 90 sh -c "tail -n +$n '$LOG' | grep -q 'host opens file'" && break
        done
        wait_for 300 sh -c "tail -n +$n '$LOG' | grep -q 'file 0 served ([0-9]\{7,\}'"; sleep 3
        printf 'sentinel-%s' "$RANDOM" | guirun pbcopy; sleep 6
        ax raise "File Explorer" role=AXWindow >/dev/null; sleep 1
        ax key ctrl+c >/dev/null      # the pasted file is still the only selection
        got=0
        for i in $(seq 1 30); do
            id=$(ax cgwindows --any-layer "$V" | awk -F'\t' '$2 == "ICA Viewer" && index($5, "Files from the session") {print $1; exit}')
            if [ -n "$id" ]; then sleep 1; snap_id "$id" clipboard-progress; got=1; break; fi
            sleep 1
        done
        [ "$got" = 1 ] || soft clipboard-progress "no progress window seen"
        sleep 30
}

# ------------------------------------------------------------ Settings, Connection Center, Report, About
has_win "$V" "ICA Viewer" || { ax key ctrl+alt+cmd+l >/dev/null; sleep 2; }
ax press "$V" id=showSettings >/dev/null 2>&1 || { ax press "$V" subrole=AXMenuExtra desc="ICA Viewer" >/dev/null 2>&1; sleep 1; ax press "$V" role=AXMenuItem title~"Settings" >/dev/null 2>&1; }
# Settings has four panes in a toolbar; the window is titled by the pane. Every change applies at once (no Save).
if ax wait "$V" role=AXWindow title~General --timeout 10 >/dev/null 2>&1 || has_win "$V" "General" || has_win "$V" "Account" || has_win "$V" "Devices" || has_win "$V" "Display"; then
    tree "$V" settings 14
    for pane in General Account Devices Display; do
        ax press "$V" role=AXRadioButton title="$pane" >/dev/null 2>&1 || ax press "$V" role=AXButton title="$pane" >/dev/null 2>&1 || ax press "$V" title="$pane" >/dev/null 2>&1
        sleep 2
        snap "$V" "$pane" "settings-$(echo $pane | tr A-Z a-z)"
    done
    ax key cmd+w >/dev/null; sleep 1
else miss settings-general "no Settings window"; miss settings-account; miss settings-devices; miss settings-display; fi

ax press "$V" role=AXButton title~"Connection Center" >/dev/null
if ax wait "$V" role=AXWindow title~"Connection Center" --timeout 10 >/dev/null; then
    sleep 4; snap "$V" "Connection Center" center
else miss center "no Connection Center"; fi
ax press "$V" role=AXButton title=Disconnect --index 0 >/dev/null
wait_for 25 sh -c '! guirun axrunner apps | grep -q " Notepad"'
sleep 3; ax press "$V" title=Refresh >/dev/null; sleep 5
snap "$V" "Connection Center" center-disconnected
ax press "$V" title~"Report a Problem" >/dev/null
if ax wait "$V" role=AXWindow title~"Report a Problem" --timeout 10 >/dev/null; then
    sleep 4; snap "$V" "Report a Problem" report
    ax attr "$V" desc="Report preview" AXValue >"$OUT/report-preview.txt" 2>/dev/null
    ax press "$V" role=AXButton title=Close >/dev/null; sleep 1
else miss report "no Report a Problem window"; fi
ax press "$V" id=showAbout >/dev/null; sleep 2; snap_untitled "$V" about
ax key cmd+w >/dev/null; sleep 1

# ------------------------------------------------------------ reconnect offer after a restart
stop_viewer; sleep 2
start_viewer
wait_for 60 sh -c "[ \$(guirun axrunner count '$V' role=AXRow 2>/dev/null || echo 0) -ge 1 ]"
if ax wait "$V" role=AXSheet --timeout 8 >/dev/null; then
    sleep 1; snap "$V" "ICA Viewer" reconnect-offer
    ax press "$V" role=AXButton title=Reconnect >/dev/null
    wait_for 90 has_win Notepad Notepad; sleep 3
else miss reconnect-offer "no offer sheet"; fi

# ------------------------------------------------------------ quit prompt, then log off
has_win "$V" "ICA Viewer" || { ax key ctrl+alt+cmd+l >/dev/null; sleep 2; }
ax press "$V" role=AXButton title~"Connection Center" >/dev/null; sleep 3
ax press "$V" role=AXButton title="Log Off" --index 0 >/dev/null
if ax wait "$V" role=AXSheet --timeout 6 >/dev/null; then
    sleep 1; snap "$V" "Connection Center" center-logoff
    ax press "$V" role=AXButton title=Cancel >/dev/null; sleep 1
else miss center-logoff "no confirmation sheet"; fi
ax activate "$V" >/dev/null; sleep 1; ax key cmd+q >/dev/null
if ax wait "$V" role=AXButton title~"Log Off" --timeout 8 >/dev/null; then
    sleep 1; ax cgwindows --any-layer "$V" >>"$OUT/checks.log" 2>&1
    snap_untitled "$V" quit-prompt || snap "$V" "Quit" quit-prompt
    ax press "$V" role=AXButton title=Cancel >/dev/null; sleep 1
else miss quit-prompt "no quit prompt"; fi
[ "${MANUAL_BIG:-1}" = 1 ] && big_copy
ax activate "$V" >/dev/null; sleep 1; ax key cmd+q >/dev/null
if ax wait "$V" role=AXButton title~"Log Off" --timeout 8 >/dev/null; then
    ax press "$V" role=AXButton title="Log Off" >/dev/null
    wait_for 40 sh -c "! pgrep -f '$(viewer_bin)' >/dev/null"
else stop_viewer; fi
echo "shots: $(grep -c '^OK' "$LIST") ok, $(grep -c '^MISS' "$LIST") missing"
finish
