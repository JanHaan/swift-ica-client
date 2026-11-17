#!/usr/bin/env python3 -I
"""EDT reachability probe (docs/80-edt.md §4): the two-step UDP handshake as observed from the stock client, then
listen for the VDA's keep-alives. Shows whether server-to-client EDT packets after the handshake reach this Mac.
No CGP/ICA data is sent; the VDA drops the half-open connection after about 20 s (its shutdown is printed).
usage: scripts/edt-probe.py <vda address> [port, default 2598] [seconds, default 25]"""
import os, socket, struct, sys, time

host = sys.argv[1]
port = int(sys.argv[2]) if len(sys.argv) > 2 else 2598
listen = float(sys.argv[3]) if len(sys.argv) > 3 else 25
peer = socket.inet_aton(socket.gethostbyname(host))[::-1]  # the address field as observed (little-endian)
sock_id, isn = struct.unpack(">II", os.urandom(8))
sock_id &= 0x7FFFFFFF
isn &= 0x7FFFFFFF


def handshake(version, conn_type, cookie, ext=b""):
    header = struct.pack(">IIII", 0x80000007, 0, 0, 0)
    body = struct.pack(">IIIIIiII", version, 1, isn, 1500, 16384, conn_type, sock_id, cookie)
    return header + body + peer + b"\0" * 12 + ext


s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(3)
t0 = time.time()
def show(tag, data):
    print(f"+{time.time() - t0:7.3f} {tag} len {len(data)} {data[:72].hex()}")

first = handshake(4, 1, 0)
s.sendto(first, (host, port)); show("C>S", first)
reply, _ = s.recvfrom(2048); show("S>C", reply)
cookie = struct.unpack(">I", reply[44:48])[0]
second = handshake(7, -1, cookie, struct.pack(">II", sock_id, isn))
s.sendto(second, (host, port)); show("C>S", second)
reply, _ = s.recvfrom(2048); show("S>C", reply)
server_id = struct.unpack(">I", reply[40:44])[0]
print(f"handshake done: our socket {sock_id:08x}, server socket {server_id:08x}; listening {listen:.0f} s")
count = 0
end = time.time() + listen
while time.time() < end:
    try:
        data, _ = s.recvfrom(2048)
    except socket.timeout:
        continue
    count += 1
    show("S>C", data)
    if data[:2] == b"\x80\x05":
        break
# Tell the VDA we are gone (shutdown, as the stock client sends it).
bye = struct.pack(">IIII", 0x80050000, 0, 0, server_id) + b"\0" * 4
s.sendto(bye, (host, port)); show("C>S", bye)
print(f"{count} packets received after the handshake")
