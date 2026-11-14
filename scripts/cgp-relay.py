#!/usr/bin/env python3 -I
"""Local CGP relay for black-box recording of the stock client's own session (§69d(3)).

The stock client gets a launch file that points it at this relay without TLS (direct-mode CGP on
127.0.0.1). The relay adds the gateway's STA ticket (cap 6) to the client's BIND_REQUEST, opens TLS
to the gateway from the original launch file, and relays both directions, recording every chunk.

usage: cgp-relay.py ORIGINAL.ica OUT.ica RECORD.bin [port]
Record format: per chunk  dir(1: 'C' client->server, 'S' server->client) | u32 ms | u32 len | data
"""
import socket, ssl, struct, sys, threading, time

SIG = b"\x1aCGP/01"


def read_ica(path):
    sections, cur = {}, None
    for line in open(path, encoding="utf-8", errors="replace").read().splitlines():
        line = line.strip()
        if line.startswith("[") and line.endswith("]"):
            cur = line[1:-1]; sections[cur] = []
        elif cur is not None:
            sections[cur].append(line)
    return sections


def kv(lines):
    out = {}
    for l in lines:
        if "=" in l:
            k, v = l.split("=", 1); out[k] = v
    return out


def write_ica(orig, out, port):
    secs = read_ica(orig)
    app = next(s for s in secs["ApplicationServers"] if s.endswith("=")).rstrip("=")
    vals = kv(secs[app])
    lines = []
    drop = {"SSLProxyHost", "SSLEnable", "CGPSecurityTicket", "Address", "RemoveICAFile", "SSLCiphers",
            "SecureChannelProtocol"}
    for name, body in secs.items():
        lines.append(f"[{name}]")
        for l in body:
            k = l.split("=", 1)[0]
            if k in drop:
                continue
            lines.append(l)
        if name == app:
            lines += ["Address=127.0.0.1:1494", f"CGPAddress=*:{port}", "SSLEnable=Off", "CGPSecurityTicket=Off"]
    open(out, "w").write("\r\n".join(lines) + "\r\n")
    proxy = vals["SSLProxyHost"]
    host, _, p = proxy.rpartition(":")
    return host, int(p or 443), vals["Address"]


def varlen(b, i):
    v = b[i]
    if v < 0x80:
        return v, i + 1
    return (v & 0x7F) | (b[i + 1] << 7), i + 2


def enc_varlen(v):
    return bytes([v]) if v < 0x80 else bytes([(v & 0x7F) | 0x80, v >> 7])


def read_exact(s, n):
    buf = b""
    while len(buf) < n:
        c = s.recv(n - len(buf))
        if not c:
            raise EOFError
        buf += c
    return buf


def read_packet(s):
    """One CGP packet (varlen length incl. command byte, then body) as raw bytes."""
    first = read_exact(s, 1)
    if first[0] < 0x80:
        hdr, n = first, first[0]
    else:
        second = read_exact(s, 1); hdr = first + second; n = (first[0] & 0x7F) | (second[0] << 7)
    return hdr + read_exact(s, n)


def inject_ticket(pkt, ticket):
    """BIND_REQUEST: varlen len | 0x01 | u8 | u16 | varlen ncaps | caps (each varlen len | svc u16 | cap u16 | u16 | body)."""
    n, i = varlen(pkt, 0)
    assert pkt[i] == 0x01, f"not a BIND_REQUEST: {pkt[:8].hex()}"
    head = pkt[i + 1:i + 4]
    ncaps, j = varlen(pkt, i + 4)
    caps = []
    for _ in range(ncaps):
        ln, k = varlen(pkt, j)
        caps.append(pkt[j:k + ln]); j = k + ln
    t = ticket.encode()
    body6 = b"\x00" + enc_varlen(len(t)) + t
    cap6 = enc_varlen(6 + len(body6)) + struct.pack("<HHH", 0, 6, 0) + body6
    ids = []
    for c in caps:
        _, k = varlen(c, 0); ids.append(struct.unpack_from("<H", c, k + 2)[0])
    had6 = 6 in ids
    caps = [c for c, cid in zip(caps, ids) if cid != 6]
    pos = next((x for x, cid in enumerate([c for c in ids if c != 6]) if cid == 2), len(caps))
    caps.insert(pos, cap6)
    body = b"\x01" + head + enc_varlen(len(caps)) + b"".join(caps)
    return enc_varlen(len(body)) + body, ids, had6


class Recorder:
    def __init__(self, path):
        self.f = open(path, "wb"); self.t0 = time.time(); self.lock = threading.Lock()

    def put(self, d, data):
        with self.lock:
            self.f.write(d + struct.pack("<II", int((time.time() - self.t0) * 1000), len(data)) + data)
            self.f.flush()


def pump(src, dst, rec, d, done):
    try:
        while True:
            c = src.recv(65536)
            if not c:
                break
            rec.put(d, c); dst.sendall(c)
    except OSError:
        pass
    finally:
        done.set()


def main():
    orig, out, record = sys.argv[1:4]
    port = int(sys.argv[4]) if len(sys.argv) > 4 else 2598
    host, gport, ticket = write_ica(orig, out, port)
    rec = Recorder(record)
    lst = socket.socket(); lst.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    lst.bind(("127.0.0.1", port)); lst.listen(4)
    plain = socket.socket(); plain.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    plain.bind(("127.0.0.1", 1494)); plain.listen(1)

    def watch_plain():
        c, _ = plain.accept()
        print("WARN: client fell back to plain ICA on 1494 (no CGP); first bytes:", c.recv(64).hex(), flush=True)
        c.close()
    threading.Thread(target=watch_plain, daemon=True).start()
    print(f"ready: listening 127.0.0.1:{port}, gateway {host}:{gport}, wrote {out}", flush=True)
    cli, _ = lst.accept()
    print("client connected", flush=True)
    sig = read_exact(cli, len(SIG))
    rec.put(b"C", sig)
    assert sig == SIG, f"no CGP signature: {sig.hex()}"
    bind = read_packet(cli)
    rec.put(b"c", bind)  # original bind, before injection
    newbind, ids, had6 = inject_ticket(bind, ticket)
    print(f"client bind caps {ids} (had cap 6: {had6}); injected STA ticket", flush=True)
    ctx = ssl.create_default_context()
    srv = ctx.wrap_socket(socket.create_connection((host, gport), timeout=20), server_hostname=host)
    srv.settimeout(None)
    srv.sendall(SIG + newbind)
    rec.put(b"C", newbind)
    done = threading.Event()
    threading.Thread(target=pump, args=(cli, srv, rec, b"C", done), daemon=True).start()
    threading.Thread(target=pump, args=(srv, cli, rec, b"S", done), daemon=True).start()
    done.wait()
    print("connection closed", flush=True)
    time.sleep(1)


if __name__ == "__main__":
    main()
