#!/usr/bin/env python3
"""A WebSocket server that pings every second and sends no data, for the
`receive_within!` deadline tests. Python stdlib only.

The text message "data-after:<s>" makes it send the text "data" <s> seconds
later (it keeps pinging meanwhile). A Close is echoed. Usage: ping_server.py [port]
"""
import base64, hashlib, socket, struct, sys, threading, time

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
    opcode, length = b0 & 15, b1 & 127
    if length == 126:
        length = struct.unpack(">H", recv_exact(conn, 2))[0]
    elif length == 127:
        length = struct.unpack(">Q", recv_exact(conn, 8))[0]
    key = recv_exact(conn, 4)
    data = bytes(b ^ key[i % 4] for i, b in enumerate(recv_exact(conn, length)))
    return opcode, data


def frame(opcode, payload):
    n = len(payload)
    assert n < 126
    return bytes([0x80 | opcode, n]) + payload


def handle(conn):
    lock = threading.Lock()
    done = threading.Event()

    def send(data):
        with lock:
            conn.sendall(data)

    def pinger():
        while not done.wait(1.0):
            try:
                send(frame(9, b"tick"))
            except OSError:
                return

    def later(seconds):
        time.sleep(seconds)
        try:
            send(frame(1, b"data"))
        except OSError:
            pass

    try:
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = conn.recv(1)
            if not chunk:
                return
            head += chunk
        headers = {}
        for line in head.decode().split("\r\n")[1:]:
            if ":" in line:
                k, v = line.split(":", 1)
                headers[k.strip().lower()] = v.strip()
        accept = base64.b64encode(hashlib.sha1(headers["sec-websocket-key"].encode() + GUID).digest()).decode()
        send(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n" % accept).encode())
        log("client connected")
        threading.Thread(target=pinger, daemon=True).start()
        while True:
            opcode, data = read_frame(conn)
            if opcode == 8:
                send(frame(8, data[:2]))
                return
            if opcode == 9:
                send(frame(10, data))
            elif opcode == 1 and data.startswith(b"data-after:"):
                threading.Thread(target=later, args=(float(data[11:]),), daemon=True).start()
    except (EOFError, ConnectionError) as e:
        log("connection ended:", repr(e))
    finally:
        done.set()
        conn.close()


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9003
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen()
    log("listening on", port)
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=handle, args=(conn,), daemon=True).start()


main()
