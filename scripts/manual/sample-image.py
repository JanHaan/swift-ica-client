# Writes a small sample picture (a sky-to-sea gradient with a sun) for the manual's clipboard screenshot.
# usage: python3 -I sample-image.py out.png
import struct, sys, zlib

w, h = 280, 180
rows = []
for y in range(h):
    row = bytearray([0])
    for x in range(w):
        t = y / h
        r, g, b = int(90 + 120 * t), int(150 + 60 * t), int(235 - 120 * t)
        if (x - 200) ** 2 + (y - 55) ** 2 < 28 ** 2:
            r, g, b = 255, 214, 64
        if y > 120:
            r, g, b = 30, int(110 + (y - 120)), 170
        row += bytes((r, g, b))
    rows.append(bytes(row))

def chunk(tag, data):
    c = struct.pack(">I", len(data)) + tag + data
    return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(b"".join(rows), 9)) + chunk(b"IEND", b"")
open(sys.argv[1], "wb").write(png)
