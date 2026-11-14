#!/usr/bin/env python3 -I
"""Split a cgp-relay record into per-direction ICA byte streams and a CGP packet log."""
import struct, sys
rec, outdir = sys.argv[1], sys.argv[2]
raw = open(rec, "rb").read()
streams = {"C": b"", "S": b""}
i = 0
while i < len(raw):
    d = chr(raw[i]); t, n = struct.unpack_from("<II", raw, i + 1); data = raw[i + 9:i + 9 + n]; i += 9 + n
    if d in streams: streams[d] += data
SIG = b"\x1aCGP/01"
def vl(b, i):
    v = b[i]
    return (v, i + 1) if v < 0x80 else ((v & 0x7F) | (b[i + 1] << 7), i + 2)
def flags(b, i):  # readFlags: flag byte then optional fields; mirror CGP.swift best-effort
    return i
log = open(f"{outdir}/cgp.log", "w")
for d, s in streams.items():
    assert s.startswith(SIG), (d, s[:8])
    i = len(SIG); ica = b""; cmds = {}
    while i < len(s):
        n, j = vl(s, i)
        if j + n > len(s): break
        pkt = s[j:j + n]; i = j + n
        cmd = pkt[0]; cmds[cmd] = cmds.get(cmd, 0) + 1
        if cmd == 0x0a: ica += pkt[1:]
        elif cmd == 0x0b:
            _, k = vl(pkt, 1); ica += pkt[k:]
        else:
            log.write(f"{d} cmd {cmd:#04x} len {n}: {pkt[:48].hex()}\n")
    open(f"{outdir}/ica-{d}.bin", "wb").write(ica)
    print(d, "cgp cmds", {hex(k): v for k, v in cmds.items()}, "ica bytes", len(ica), "leftover", len(s) - i)
