#!/usr/bin/env python3
"""A small RFC 6455 echo server, Python stdlib only, for testing roc-websocket.

Echoes text and binary messages. Special text messages:
  "fragment-me"  -> replies "fragmented reply" in 3 fragments with a Ping between
  "ping-me"      -> sends a Ping "are you there" then replies "pinged"
  "close-me"     -> server starts the close with 4000 "server says bye"
  "big:<n>"      -> replies with n bytes of 'x' (binary)
  "sleep:<s>"    -> waits s seconds, then replies "woke up"
Every connection first gets a Ping "hello-ping" so the client must answer it.
Logs each event to stderr. Usage: echo_server.py [port]
"""
import base64, hashlib, socket, struct, sys, threading

GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

def log(*a):
    print(*a, file=sys.stderr, flush=True)

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
    fin, opcode = b0 >> 7, b0 & 15
    masked, length = b1 >> 7, b1 & 127
    if length == 126:
        length = struct.unpack(">H", recv_exact(conn, 2))[0]
    elif length == 127:
        length = struct.unpack(">Q", recv_exact(conn, 8))[0]
    if not masked:
        raise ValueError("client frame not masked")
    key = recv_exact(conn, 4)
    data = bytes(b ^ key[i % 4] for i, b in enumerate(recv_exact(conn, length)))
    return fin, opcode, data

def frame(opcode, payload, fin=True):
    head = bytes([(0x80 if fin else 0) | opcode])
    n = len(payload)
    if n < 126:
        head += bytes([n])
    elif n < 65536:
        head += bytes([126]) + struct.pack(">H", n)
    else:
        head += bytes([127]) + struct.pack(">Q", n)
    return head + payload

def handle(conn, addr):
    try:
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = conn.recv(1)
            if not chunk:
                return
            head += chunk
        lines = head.decode().split("\r\n")
        log("request:", lines[0])
        headers = {}
        for line in lines[1:]:
            if ":" in line:
                k, v = line.split(":", 1)
                headers[k.strip().lower()] = v.strip()
        key = headers["sec-websocket-key"].encode()
        accept = base64.b64encode(hashlib.sha1(key + GUID).digest()).decode()
        offered = [p.strip() for p in headers.get("sec-websocket-protocol", "").split(",") if p.strip()]
        proto = "echo" if "echo" in offered else None
        resp = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n" % accept
        if proto:
            resp += "Sec-WebSocket-Protocol: %s\r\n" % proto
        # The first frame goes in the same write as the response head.
        conn.sendall((resp + "\r\n").encode() + frame(9, b"hello-ping"))
        assembling = None
        while True:
            fin, opcode, data = read_frame(conn)
            log("frame: fin=%d opcode=%d len=%d %r" % (fin, opcode, len(data), data[:40]))
            if opcode == 8:
                conn.sendall(frame(8, data[:2]))
                log("closed by client:", data[:2].hex(), data[2:].decode(errors="replace"))
                return
            if opcode == 9:
                conn.sendall(frame(10, data))
                continue
            if opcode == 10:
                log("pong:", data)
                continue
            if opcode in (1, 2):
                assembling = (opcode, data)
            elif opcode == 0:
                assembling = (assembling[0], assembling[1] + data)
            if not fin:
                continue
            op, msg = assembling
            assembling = None
            if op == 1 and msg == b"fragment-me":
                conn.sendall(frame(1, b"fragmented ", fin=False) + frame(9, b"mid") + frame(0, b"re", fin=False) + frame(0, b"ply"))
            elif op == 1 and msg == b"ping-me":
                conn.sendall(frame(9, b"are you there") + frame(1, b"pinged"))
            elif op == 1 and msg == b"close-me":
                conn.sendall(frame(8, struct.pack(">H", 4000) + b"server says bye"))
                fin, opcode, data = read_frame(conn)
                log("close echo: opcode=%d %r" % (opcode, data))
                return
            elif op == 1 and msg.startswith(b"sleep:"):
                import time
                time.sleep(int(msg[6:]))
                conn.sendall(frame(1, b"woke up"))
            elif op == 1 and msg.startswith(b"big:"):
                conn.sendall(frame(2, b"x" * int(msg[4:])))
            else:
                conn.sendall(frame(op, msg))
    except (EOFError, ConnectionError) as e:
        log("connection ended:", repr(e))
    finally:
        conn.close()

def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9001
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen()
    log("listening on", port)
    while True:
        conn, addr = srv.accept()
        threading.Thread(target=handle, args=(conn, addr), daemon=True).start()

main()
