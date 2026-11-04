#!/usr/bin/env python3
"""Checks examples/server.roc with an independent client, Python `websockets`.

Usage: server_test.py <port> one|many|raw|close. Prints `ok <name>` for each check
and exits 1 at the first failure. `one` and `many` are for `server one` and
`server many` (`many` also runs several clients at once), `raw` for `server
raw`, and `close` for the Close sent with the last messages only (the caller
then reads the server's `on_close!` line). The checks through the `websockets` package (a venv is enough) are
skipped when it is not installed; the raw-socket checks use the stdlib only.
"""
import asyncio, base64, os, socket, struct, sys, time

try:
    import websockets
    from websockets.asyncio.client import connect
except ImportError:
    websockets = None

PORT = int(sys.argv[1])
MODE = sys.argv[2]
MANY = MODE == "many"
URL = "ws://127.0.0.1:%d" % PORT


def ok(name, passed, detail=""):
    if not passed:
        print("FAIL %s %s" % (name, detail), flush=True)
        sys.exit(1)
    print("ok   %s %s" % (name, detail), flush=True)


async def echo_and_protocol():
    async with connect(URL + "/echo", subprotocols=["chat", "echo"]) as ws:
        # The server supports [echo, chat]: its order of preference decides.
        ok("subprotocol: the server's order of preference", ws.subprotocol == "echo", ws.subprotocol)
        await ws.send("hello")
        ok("echo text", await ws.recv() == "hello")
        await ws.send(bytes([0, 1, 2, 255]))
        ok("echo binary", await ws.recv() == bytes([0, 1, 2, 255]))
        await ws.send("fragment-me")
        ok("fragmented reply with a Ping inside", await ws.recv() == "fragmented reply")
        await ws.send("ping-me")
        ok("reply after a server Ping", await ws.recv() == "pinged")
    async with connect(URL + "/versions", subprotocols=["v2", "chat"]) as ws:
        # /versions supports [chat, v2]: not the client's order.
        ok("subprotocol: offered [v2, chat], supported [chat, v2]", ws.subprotocol == "chat", ws.subprotocol)
    async with connect(URL + "/echo", subprotocols=["superchat"]) as ws:
        ok("subprotocol: none when nothing matches", ws.subprotocol is None)
    async with connect(URL + "/") as ws:
        ok("subprotocol: none offered", ws.subprotocol is None)


async def refusals():
    for path, status in (("/missing/x", 404), ("/private", 403)):
        try:
            async with connect(URL + path):
                ok("refusal %d" % status, False, "accepted")
        except websockets.exceptions.InvalidStatus as e:
            r = e.response
            ok("refusal %d" % status, r.status_code == status, "%d %r" % (r.status_code, r.body))
            if status == 404:
                ok("refusal headers and body", r.headers.get("X-Route") == "none" and b"/missing/x" in r.body)


async def client_close():
    async with connect(URL + "/echo") as ws:
        await ws.send("x")
        await ws.recv()
        start = time.monotonic()
        await ws.close(1000, "bye")
        took = time.monotonic() - start
        ok("client close: clean", ws.close_code == 1000, "code %s" % ws.close_code)
        # websockets waits for the server to close TCP (up to close_timeout = 10 s).
        ok("client close: the server closes TCP at once", took < 1.0, "%.3f s" % took)


async def server_close():
    async with connect(URL + "/echo") as ws:
        await ws.send("close-me")
        try:
            await ws.recv()
            ok("server close", False, "a message")
        except websockets.exceptions.ConnectionClosed as e:
            ok("server close: 4000 and its reason", e.rcvd.code == 4000 and e.rcvd.reason == "server says bye", repr(e.rcvd))


async def ping():
    async with connect(URL + "/echo") as ws:
        start = time.monotonic()
        waiter = await ws.ping(b"from python")
        latency = await asyncio.wait_for(waiter, 5)
        ok("client Ping answered", True, "%.1f ms" % (1000 * (time.monotonic() - start)))


async def large():
    async with connect(URL + "/echo", max_size=4 * 1024 * 1024) as ws:
        payload = os.urandom(1024 * 1024 - 16)
        await ws.send(payload)
        ok("echo of a 1 MiB message", await ws.recv() == payload)
        await ws.send("big:3000000")
        got = await ws.recv()
        ok("a 3 MB message from the server", got == b"x" * 3000000)
        try:
            # The server fails the message at its frame header and closes TCP
            # while the client may still be writing: the send itself can fail.
            await ws.send(b"y" * (1024 * 1024 + 1))
            await ws.recv()
            ok("over max_message", False, "a message")
        except websockets.exceptions.ConnectionClosedError as e:
            ok("over max_message: 1009", e.rcvd is not None and e.rcvd.code == 1009, repr(e.rcvd))


# ------------------------------------------------------------- raw sockets

def masked(opcode, payload, fin=True):
    head = bytes([(0x80 if fin else 0) | opcode])
    n = len(payload)
    if n < 126:
        head += bytes([0x80 | n])
    elif n < 65536:
        head += bytes([0x80 | 126]) + struct.pack(">H", n)
    else:
        head += bytes([0x80 | 127]) + struct.pack(">Q", n)
    key = os.urandom(4)
    return head + key + bytes(b ^ key[i % 4] for i, b in enumerate(payload))


def read_frames(sock, timeout=2.0):
    """Every frame the server sends until it closes TCP (or `timeout`), and
    whether it closed TCP."""
    sock.settimeout(timeout)
    data = b""
    closed = False
    try:
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                closed = True
                break
            data += chunk
    except socket.timeout:
        pass
    frames = []
    while len(data) >= 2:
        op, n = data[0] & 15, data[1] & 127
        i = 2
        if n == 126:
            n, i = struct.unpack(">H", data[2:4])[0], 4
        elif n == 127:
            n, i = struct.unpack(">Q", data[2:10])[0], 10
        frames.append((op, data[i:i + n]))
        data = data[i + n:]
    return frames, closed


def raw_open(extra=b"", headers=b""):
    sock = socket.create_connection(("127.0.0.1", PORT))
    key = base64.b64encode(os.urandom(16))
    request = (b"GET /echo HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
               b"Sec-WebSocket-Key: " + key + b"\r\nSec-WebSocket-Version: 13\r\n" + headers + b"\r\n")
    sock.sendall(request + extra)
    head = b""
    while b"\r\n\r\n" not in head:
        head += sock.recv(1)
    return sock, head


def messages_with_close():
    # The client's last messages and its Close in one write, so the server
    # reads them in one read.
    sock, head = raw_open()
    ok("raw: 101", head.startswith(b"HTTP/1.1 101"))
    sock.sendall(masked(1, b"one") + masked(1, b"two") + masked(8, struct.pack(">H", 1000)))
    frames, closed = read_frames(sock)
    texts = [p for (op, p) in frames if op == 1]
    close = [p for (op, p) in frames if op == 8]
    print("     frames after the 101: %r; TCP closed: %s" % ([(op, p[:20]) for op, p in frames], closed))
    ok("messages with the Close in one read: the Close is echoed", close == [struct.pack(">H", 1000)])
    ok("messages with the Close in one read: TCP closed by the server", closed)
    # The echo of the Close is held until both messages are answered.
    ok("messages with the Close in one read: both are answered", texts == [b"one", b"two"], repr(texts))
    ok("messages with the Close in one read: the replies come before the Close",
       [op for (op, _) in frames if op in (1, 8)] == [1, 1, 8], repr(frames))
    return texts


def first_frames_with_request():
    # Frames right behind the request head, in the same write.
    sock, head = raw_open(masked(1, b"early") + masked(8, struct.pack(">H", 1000)))
    frames, closed = read_frames(sock)
    print("     frames after the 101: %r" % [(op, p[:20]) for op, p in frames])
    ok("frames sent with the request are read", any(op == 8 for op, _ in frames))


def unmasked_frame():
    sock, head = raw_open()
    sock.sendall(bytes([0x81, 2]) + b"hi")
    frames, closed = read_frames(sock)
    codes = [struct.unpack(">H", p[:2])[0] for (op, p) in frames if op == 8]
    ok("an unmasked client frame fails with 1002", 1002 in codes, repr(codes))
    ok("and TCP is closed", closed)


def not_an_upgrade():
    sock = socket.create_connection(("127.0.0.1", PORT))
    sock.sendall(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n")
    sock.settimeout(2)
    reply = b""
    try:
        while True:
            chunk = sock.recv(4096)
            if not chunk:
                break
            reply += chunk
    except socket.timeout:
        pass
    ok("a plain HTTP request is refused with 400", reply.startswith(b"HTTP/1.1 400"), repr(reply[:40]))


async def several():
    async def one(i):
        async with connect(URL + "/echo") as ws:
            for j in range(20):
                text = "client %d message %d" % (i, j)
                await ws.send(text)
                if await ws.recv() != text:
                    return False
            return True
    start = time.monotonic()
    results = await asyncio.gather(*(one(i) for i in range(5)))
    ok("5 clients at once, 20 echoes each", all(results), "%.2f s" % (time.monotonic() - start))


def two_step():
    # `server raw`: it accepts the last subprotocol offered, echoes, and polls
    # with a 200 ms read timeout while the client is quiet.
    sock, head = raw_open(headers=b"Sec-WebSocket-Protocol: first, second\r\n")
    ok("raw: the application's own subprotocol choice", b"Sec-WebSocket-Protocol: second" in head, repr(head))
    sock.sendall(masked(1, b"before a pause"))
    time.sleep(0.7)
    sock.sendall(masked(1, b"after a pause"))
    time.sleep(0.2)
    sock.sendall(masked(8, struct.pack(">H", 1000)))
    frames, closed = read_frames(sock)
    texts = [p for (op, p) in frames if op == 1]
    ok("raw: echoes across idle polls", texts == [b"before a pause", b"after a pause"], repr(texts))
    ok("raw: the Close echoed and TCP closed", any(op == 8 for op, _ in frames) and closed)


async def main():
    if MODE == "raw":
        two_step()
        return
    if MODE == "close":
        messages_with_close()
        return
    if websockets is None:
        print("skip the checks through `websockets`: not installed")
    else:
        await independent()
    texts = messages_with_close()
    print("     echoes of the messages sent with the Close: %r" % texts)
    first_frames_with_request()
    unmasked_frame()
    not_an_upgrade()
    if MANY and websockets is not None:
        await several()


async def independent():
    await echo_and_protocol()
    await refusals()
    await client_close()
    await server_close()
    await ping()
    await large()


asyncio.run(main())
