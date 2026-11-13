#!/bin/sh
# CTXGDT discovery matrix (docs/76 §7.1): runs `icactl cliptest-files` (Explorer Citrix ABC, fresh logon only, test
# folder created and deleted by the test, guarded logoff) once per variant, one change each on top of
# ICA_GDT=1 ICA_CLIP_VERSION=4, sequentially, with a fresh gateway login before each run and a 20 s pause between
# runs. Prints one summary line per variant (host GDT packets, file-format requests, CTXCTL caps) from icactl's
# MATRIX line. V7 and V8 build on V6 (and V8 on V7) by design; V11/V12 on V10; V13 = V9 with cap 07 echoed.
# V14–V17 name the modules as the stock client does (V15+ also check cdm_connect=true: CTXCDM CONNECT); V17 =
# V16 + CTXCAM with every announced module named and versioned from the stock list (docs/76 §7.6).
# V18–V20: client identity (UI version/build/product, cap 0x0D Mac); V19 + V17 with the full stock module list
# (now also WD/TD/PD/UI/TW/TWI names); V20 without CTXGDT (ICA_GDT=0 wins: clipboard v4 only) (docs/76 §7.8).
# V21: no cap 0x21, VD channel fields as bit masks; V22: server caps 0x2A/0x2C echoed; both with CDM (docs/76 §7.9).
# V12 also announces CTXCPM (host PDF printer), CTXCAM (playback, no sink) and CTXMM (no frames) and stubs for
# every other stock channel, all on the stock client's channel numbers (docs/76 §7.4).
# Usage: scripts/gdt-matrix.sh [variant ...]   (default: all; names V1 V2 V3a V3b V5a V5b V6 V7 V8 V10 V11 V12 V13 V14 V15 V16 V17 V18 V19 V20 V21 V22)
# Logs: /tmp/icashot/gdt-matrix-<time>/<variant>.log; GDT hex logs in .session/gdt/.
# Never kills processes: a run that hangs is left to icactl's own timeouts.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
swift build --product icactl || exit 1
bin="$(swift build --show-bin-path)/icactl"
out="/tmp/icashot/gdt-matrix-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$out"
chmod 700 "$out"

# name|extra environment (space-separated KEY=VALUE, no spaces inside values)
all="
V1|ICA_GDT_VDDATA=8713
V2|ICA_WD_HT=1
V3a|ICA_GDT_VERSION=1-2
V3b|ICA_GDT_VERSION=0-1
V5a|ICA_CLIP_REPLY_WORD2=1
V5b|ICA_CLIP_REPLY_TAIL=010000000000
V6|ICA_CTXCTL=1
V7|ICA_CTXCTL=1 ICA_CTL_ACCEPT=09
V8|ICA_CTXCTL=1 ICA_CTL_ACCEPT=09 ICA_WD_HT=1
V10|ICA_GDT_CDM=1
V11|ICA_GDT_CDM=1 ICA_STUB_VCS=CTXFILE
V12|ICA_GDT_CDM=1 ICA_CTXCTL=1 ICA_STOCK_VCS=1
V13|ICA_CTXCTL=1 ICA_CTL_ACCEPT=09,07,0f ICA_WD_HT=1
V14|ICA_MODNAME_CTXGDT=ClientGDT ICA_MODVER_CTXGDT=1-1
V15|ICA_MODNAME_CTXGDT=ClientGDT ICA_MODVER_CTXGDT=1-1 ICA_GDT_CDM=1 ICA_MODNAME_CTXCDM=ClientDrive ICA_MODVER_CTXCDM=1-9
V16|ICA_MODNAME_CTXGDT=ClientGDT ICA_MODVER_CTXGDT=1-1 ICA_GDT_CDM=1 ICA_MODNAME_CTXCDM=ClientDrive ICA_MODVER_CTXCDM=1-9 ICA_MODNAME_CTXCLIP=Clipboard ICA_MODVER_CTXCLIP=0-3 ICA_CTXCTL=1 ICA_MODNAME_CTXCTL=ControlChannel ICA_MODVER_CTXCTL=1-2
V17|ICA_GDT_CDM=1 ICA_CTXCTL=1 ICA_GDT_AUDIO=1 ICA_STOCK_NAMES=1
V18|ICA_UI_VERSION=26.09.0.17 ICA_UI_BUILD=17 ICA_UI_PRODUCT=- ICA_WD_OSCAP=3
V19|ICA_UI_VERSION=26.09.0.17 ICA_UI_BUILD=17 ICA_UI_PRODUCT=- ICA_WD_OSCAP=3 ICA_GDT_CDM=1 ICA_CTXCTL=1 ICA_GDT_AUDIO=1 ICA_STOCK_NAMES=1
V20|ICA_UI_VERSION=26.09.0.17 ICA_UI_BUILD=17 ICA_UI_PRODUCT=- ICA_WD_OSCAP=3 ICA_GDT=0
V21|ICA_GDT_CDM=1 ICA_WD_VCMASK=1
V22|ICA_GDT_CDM=1 ICA_WD_ECHO_CAPS=2a,2c
"
# V4 (client hello when the channel opens) has no plausible frame yet (docs/76 §7.1); run it by hand with
# ICA_GDT_HELLO=<hex> once a guess exists.

wanted="${*:-}"
summary="$out/summary.txt"
first=1
echo "$all" | while IFS='|' read -r name extra; do
    [ -n "$name" ] || continue
    if [ -n "$wanted" ]; then
        case " $wanted " in *" $name "*) ;; *) continue ;; esac
    fi
    [ "$first" = 1 ] || { echo "pause 20 s"; sleep 20; }
    first=0
    log="$out/$name.log"
    echo "=== $name: $extra"
    if ! "$bin" login > "$out/$name-login.log" 2>&1; then
        line="$name ($extra): login FAILED, see $out/$name-login.log"
    else
        # shellcheck disable=SC2086
        env ICA_GDT=1 ICA_CLIP_VERSION=4 $extra "$bin" cliptest-files > "$log" 2>&1
        status=$?
        matrix="$(grep -o 'MATRIX .*' "$log" | tail -1)"
        line="$name ($extra): exit $status ${matrix:-no MATRIX line}"
    fi
    echo "$line"
    echo "$line" >> "$summary"
done
echo "summary: $summary"
