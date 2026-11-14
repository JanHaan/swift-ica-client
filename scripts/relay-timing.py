#!/usr/bin/env python3 -I
"""Merge wd-C.log / wd-S.log (icactl relay-decode) into one time-ordered list using record.bin and the wd-X.idx
timing index (end offset of each packet's frame in ica-X.bin). Usage: relay-timing.py <relay dir> [out file].
Output lines: `<ms> <C|S> <wd log line>` (the handshake lines are left out). Private data: write under /tmp or .session."""
import struct, sys
d = sys.argv[1]
out = open(sys.argv[2], "w") if len(sys.argv) > 2 else sys.stdout
raw = open(f"{d}/record.bin", "rb").read()
SIG = b"\x1aCGP/01"


def vl(b, i):
    v = b[i]
    return (v, i + 1) if v < 0x80 else ((v & 0x7F) | (b[i + 1] << 7), i + 2)


# Per direction: the CGP byte stream with the record time of each byte range, then the ICA offset → time map.
chunks = {"C": [], "S": []}
i = 0
while i < len(raw):
    dirc = chr(raw[i]); t, n = struct.unpack_from("<II", raw, i + 1); data = raw[i + 9:i + 9 + n]; i += 9 + n
    if dirc in chunks: chunks[dirc].append((t, data))
icamap = {}
for dirc, parts in chunks.items():
    s = b"".join(p for _, p in parts)
    ends = []  # cumulative stream end per record, with time
    acc = 0
    for t, p in parts:
        acc += len(p); ends.append((acc, t))

    def time_at(pos, ends=ends):
        for e, t in ends:
            if e >= pos: return t
        return ends[-1][1]
    j = len(SIG); ica = 0; points = []
    while j < len(s):
        n, k = vl(s, j)
        if k + n > len(s): break
        pkt = s[k:k + n]; j = k + n
        if pkt[0] == 0x0a: ica += len(pkt) - 1
        elif pkt[0] == 0x0b:
            _, m = vl(pkt, 1); ica += len(pkt) - m
        else: continue
        points.append((ica, time_at(j)))
    icamap[dirc] = points


def ica_time(dirc, off):
    for e, t in icamap[dirc]:
        if e >= off: return t
    return icamap[dirc][-1][1]


rows = []
for dirc in "CS":
    lines = [l.rstrip("\n") for l in open(f"{d}/wd-{dirc}.log") if not l.startswith("HS")]
    idx = open(f"{d}/wd-{dirc}.idx").read().split("\n")
    for n, (line, off) in enumerate(zip(lines, idx)):
        t = ica_time(dirc, int(off)) if off.isdigit() else -1
        rows.append((t, 0 if dirc == "S" else 1, n, dirc, line))
rows.sort()
for t, _, _, dirc, line in rows:
    out.write(f"{t:7d} {dirc} {line[:160]}\n")
