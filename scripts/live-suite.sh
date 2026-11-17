#!/bin/bash
# Headless live test suite, layer 1 of the test automation plan (DECISIONS.md D96).
#
# Runs the icactl clipboard tests one after another, each with a fresh logon of its own that it logs off at the end:
#   text   icactl cliptest                       "Notepad"            text both ways
#   files  icactl cliptest-files                 "Explorer Citrix ABC"   two files both ways (ICA_GDT=1 ICA_CLIP_VERSION=4)
#   image  icactl cliptest-rich image            "Paint ABC"             an image both ways, every pixel compared
#   word   icactl cliptest-word                  "Microsoft Word ABC"    text, RTF, RTF with an image (and HTML with a
#                                                                        data-URI image, informational) both ways
#
# Before each test it reads `icactl sessions list`. A session in the test's delivery group (ABC apps share one group,
# XYZ is another), or a session whose apps the store does not name, may be the user's: the test is SKIPPED and that
# session is never touched (a launch would join it instead of logging on afresh). After each test the list is read
# again; a session that was not there before is reported (the test FAILS) but never logged off by this script.
#
# Logs in at most once (`icactl login`, no ICA_GATEWAY_UA), when `sessions list` cannot sign in, at least 35 s after
# the last TOTP use; it never retries a failed login.
#
# Usage: scripts/live-suite.sh [--only name[,name…]] [--dry-run]
#   --only     run only these tests (repeatable)
#   --dry-run  list the tests and what the session check decides now; no login, no test, no build
# Output: a pass/fail/skip table on stdout and in /tmp/icashot/live-suite-<time>/summary.txt, with each test's log,
# the session lists and the login log beside it. Exit code 0 only if no test failed.
# Never kills processes: a test that hangs is left to icactl's own timeouts.
set -u

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root" || exit 2
unset ICA_GATEWAY_UA ICA_STORE_MODE

# name|delivery group|resource|extra environment|icactl arguments
tests="
text|ABC|Notepad||cliptest
files|ABC|Explorer Citrix ABC|ICA_GDT=1 ICA_CLIP_VERSION=4|cliptest-files
image|ABC|Paint ABC||cliptest-rich image
word|ABC|Microsoft Word ABC||cliptest-word
"

only=""
dry=0
while [ $# -gt 0 ]; do
    case "$1" in
        --only) [ $# -ge 2 ] || { echo "--only needs a name" >&2; exit 2; }; only="$only $(echo "$2" | tr ',' ' ')"; shift 2 ;;
        --only=*) only="$only $(echo "${1#--only=}" | tr ',' ' ')"; shift ;;
        --dry-run|-n) dry=1; shift ;;
        -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option $1 (see --help)" >&2; exit 2 ;;
    esac
done
for name in $only; do
    echo "$tests" | grep -q "^$name|" || { echo "no test named $name (text, files, image, word)" >&2; exit 2; }
done

selected() { [ -z "$only" ] && return 0; case " $only " in *" $1 "*) return 0 ;; esac; return 1; }

bin="$root/.build/debug/icactl"
stamp="$(date +%Y%m%d-%H%M%S)"
out="/tmp/icashot/live-suite-$stamp"
logged_in=0
login_failed=0

# Session rows of a `sessions list` output: "<id>|<state>|<apps>".
session_rows() {
    awk '/^Sessions\/List:/ { on = 1; next } /^ListAvailable:/ { on = 0 } on && /^  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]  / { print }' "$1" |
        sed -E 's/^  ([0-9a-f]{8})  ([^ ]+) .*apps: ?(.*)  started .*$/\1|\2|\3/'
}

# Group of a session from its app names: ABC, XYZ, or unknown (no or other names).
group_of() {
    case "$1" in
        *ABC*) echo ABC ;;
        *XYZ*) echo XYZ ;;
        *) echo unknown ;;
    esac
}

# Reads the session list into $1 (signing in once if needed). Returns 1 if the list cannot be read.
read_sessions() {
    local file="$1"
    "$bin" sessions list > "$file" 2> "$file.err" < /dev/null && grep -q '^Sessions/List:' "$file" && return 0
    if [ "$dry" = 1 ] || [ "$logged_in" = 1 ] || [ "$login_failed" = 1 ]; then return 1; fi
    # TOTP: at least 35 s since the last code was used (icactl itself also waits for a new window).
    local last now gap
    last="$(stat -f %m "$root/.session/totp-last" 2>/dev/null || echo 0)"
    now="$(date +%s)"
    gap=$((now - last))
    if [ "$gap" -lt 35 ]; then echo "  waiting $((35 - gap)) s before the login (TOTP)"; sleep $((35 - gap)); fi
    echo "  signing in (icactl login)"
    logged_in=1
    if ! "$bin" login > "$out/login.log" 2>&1 < /dev/null; then
        login_failed=1
        echo "  login FAILED, see $out/login.log"
        return 1
    fi
    "$bin" sessions list > "$file" 2> "$file.err" < /dev/null && grep -q '^Sessions/List:' "$file"
}

# Sets $blocker to a reason if a session in group $1 (or of unknown group) exists in list file $2.
check_group() {
    blocker=""
    local id state apps g
    while IFS='|' read -r id state apps; do
        [ -n "$id" ] || continue
        g="$(group_of "$apps")"
        if [ "$g" = "$1" ] || [ "$g" = unknown ]; then
            blocker="${blocker:+$blocker; }session $id ($state, apps: ${apps:-none named}) is in the $1 group or its group is unknown"
        fi
    done <<EOF
$(session_rows "$2")
EOF
}

if [ "$dry" = 1 ]; then
    out="$(mktemp -d /tmp/live-suite-dry.XXXXXX)"
    echo "live suite (dry run): tests in order"
    echo "$tests" | while IFS='|' read -r name group resource extra cmd; do
        [ -n "$name" ] || continue
        selected "$name" || continue
        printf '  %-6s %-4s %-22s icactl %s%s\n' "$name" "$group" "\"$resource\"" "$cmd" "${extra:+   ($extra)}"
    done
    if [ -x "$bin" ] && read_sessions "$out/sessions.txt"; then
        echo "session check now:"
        rows="$(session_rows "$out/sessions.txt")"
        [ -n "$rows" ] || echo "  no sessions"
        echo "$rows" | while IFS='|' read -r id state apps; do
            [ -n "$id" ] && echo "  $id $state apps: ${apps:-none named} → group $(group_of "$apps")"
        done
        for g in ABC; do
            check_group "$g" "$out/sessions.txt"
            if [ -n "$blocker" ]; then echo "  $g tests would be SKIPPED: $blocker"; else echo "  $g tests would run"; fi
        done
    else
        echo "session check: not signed in to the store (a real run logs in once)"
    fi
    rm -rf "$out"
    exit 0
fi

mkdir -p "$out" && chmod 700 "$out"
summary="$out/summary.txt"
echo "live suite $stamp: logs in $out"
swift build --product icactl > "$out/build.log" 2>&1 || { echo "build failed, see $out/build.log"; exit 2; }

failed=0
first=1
results=""
add() {
    results="$results$(printf '%-6s %-8s %s' "$1" "$2" "$3")
"
    printf '%-6s %-8s %s\n' "$1" "$2" "$3"
}

while IFS='|' read -r name group resource extra cmd; do
    [ -n "$name" ] || continue
    selected "$name" || continue
    echo "=== $name: icactl $cmd in \"$resource\"${extra:+ ($extra)}"
    if [ "$login_failed" = 1 ]; then add "$name" SKIPPED "no store sign-in (the one login failed)"; continue; fi
    [ "$first" = 1 ] || { echo "  pause 20 s"; sleep 20; }
    first=0
    before="$out/$name-sessions-before.txt"
    if ! read_sessions "$before"; then
        add "$name" FAILED "cannot read the session list (sign-in failed?), see $before.err"
        failed=1
        continue
    fi
    check_group "$group" "$before"
    if [ -n "$blocker" ]; then
        add "$name" SKIPPED "$blocker"
        continue
    fi
    log="$out/$name.log"
    # shellcheck disable=SC2086
    env $extra "$bin" $cmd > "$log" 2>&1 < /dev/null
    status=$?
    result="$(grep -o 'RESULT: .*' "$log" | tail -1)"
    # A session that was not there before is left over (the logoff may still be finishing: look twice).
    after="$out/$name-sessions-after.txt"
    leftover=""
    for wait in 10 20; do
        sleep "$wait"
        leftover=""
        if read_sessions "$after"; then
            while IFS='|' read -r id state apps; do
                [ -n "$id" ] || continue
                grep -q "^  $id  " "$before" || leftover="${leftover:+$leftover; }$id ($state, apps: ${apps:-none named})"
            done <<EOF
$(session_rows "$after")
EOF
        else
            leftover="session list unreadable after the test"
        fi
        [ -z "$leftover" ] && break
    done
    case "$result" in
        "RESULT: PASS"*) verdict=PASSED; detail="${result#RESULT: PASS }" ;;
        "RESULT: FAIL"*) verdict=FAILED; detail="${result#RESULT: FAIL }" ;;
        *) verdict=FAILED; detail="no RESULT line (exit $status), see $log" ;;
    esac
    if [ -n "$leftover" ]; then
        verdict=FAILED
        detail="$detail; LEFT OVER: $leftover (not touched; log it off with icactl sessions logoff <id> if it is the test's)"
    fi
    [ "$verdict" = FAILED ] && failed=1
    add "$name" "$verdict" "$detail"
done <<EOF
$tests
EOF

{
    echo "live suite $stamp ($out)"
    printf '%-6s %-8s %s\n' test result detail
    printf '%s' "$results"
} > "$summary"
echo
cat "$summary"
[ "$failed" = 0 ]
