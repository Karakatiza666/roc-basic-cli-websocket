#!/usr/bin/env python3
"""A WebSocket client that pings every second, for the `receive_within!`
deadline test of `server deadline`. Python stdlib only.

It connects, pings every second, sends the text "late" 4.5 s after it
connected, and answers the server's Close. Usage: ping_client.py <port>
"""
import base64, os, socket, struct, sys, threading, time

PORT = int(sys.argv[1])


def masked(opcode, payload):
    key = os.urandom(4)
    body = bytes(b ^ key[i % 4] for i, b in enumerate(payload))
    return bytes([0x80 | opcode, 0x80 | len(payload)]) + key + body


def recv_exact(conn, n):
    buf = b""
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            raise EOFError
        buf += chunk
    return buf


def read_frame(conn):
    b0, b1 = recv_exact(conn, 2)
    opcode, length = b0 & 15, b1 & 127
    if length == 126:
        length = struct.unpack(">H", recv_exact(conn, 2))[0]
    elif length == 127:
        length = struct.unpack(">Q", recv_exact(conn, 8))[0]
    return opcode, recv_exact(conn, length)


conn = socket.create_connection(("127.0.0.1", PORT))
key = base64.b64encode(os.urandom(16)).decode()
conn.sendall(("GET / HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n" % (PORT, key)).encode())
head = b""
while b"\r\n\r\n" not in head:
    head += conn.recv(1)
assert b" 101 " in head.split(b"\r\n")[0], head
start = time.monotonic()
lock = threading.Lock()


def send(data):
    with lock:
        conn.sendall(data)


def pinger():
    while True:
        time.sleep(1.0)
        send(masked(9, b"tick"))


def late():
    time.sleep(4.5)
    send(masked(1, b"late"))


threading.Thread(target=pinger, daemon=True).start()
threading.Thread(target=late, daemon=True).start()
try:
    while True:
        opcode, data = read_frame(conn)
        if opcode == 8:
            send(masked(8, data[:2]))
            print("closed by the server after %.1f s" % (time.monotonic() - start), flush=True)
            break
except (EOFError, ConnectionError):
    sys.exit(1)
