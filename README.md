# roc-basic-cli-websocket

WebSocket clients and servers for [basic-cli](https://github.com/roc-lang/basic-cli)
0.26.0, built on [roc-websocket](https://github.com/Karakatiza666/roc-websocket).
Use it in a command-line program to talk to a WebSocket server (`WsClient`) or
to be one (`WsServer`).

```roc
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	ws: "https://github.com/Karakatiza666/roc-websocket/releases/download/0.0.5/AKLgwxjBQN2XkE4G5sZtzrjPSxhwo6XmJRSPdWhpgVUN.tar.zst",
	cli_ws: "https://github.com/Karakatiza666/roc-basic-cli-websocket/releases/download/0.0.2/A6pcg2YPiT75rhPyftEGQPw9XtqvrLZbmWjruiDY8iHp.tar.zst",
}

import pf.OsStr
import pf.Stdout
import ws.Ws
import cli_ws.WsClient

main! : List(OsStr) => Try({}, _)
main! = |_args| {
	opened = WsClient.connect!({ url: "ws://127.0.0.1:9001/", protocols: ["echo"] })?
	sent = opened.conn.send!(Text("hi"))?
	(conn, reply) = sent.receive!()?
	_ = Ws.close_and_wait!(WsClient.ops, conn, 1000, "")?
	Stdout.line!(Str.inspect(reply))
}
```

The app must name exactly the platform URL above (one platform per build).
Each call returns the updated connection: keep using the newest one.

## API

- `WsClient.connect! : Ws.ConnectRequest => Try(Ws.Opened(WsClient.Conn), WsClient.Error)`
- `WsClient.connect_with! : Ws.ConnectRequest, WsClient.Options => ...`, the same with
  the platform's timeouts. `WsClient.Options = { connect_timeout ?: Duration, read_timeout ?: Duration, write_timeout ?: Duration }`
  (`Duration` is `pf.Duration`; defaults 5 s, 30 s, 30 s).
- `WsClient.Conn = Client.Conn(WsClient.Link, WsClient.Errors)`, with the methods
  `send!`, `receive!`, `poll!`, `close!`, `ping!`, `pong!`, `send_frame!`,
  `receive_frame!`.
- `WsClient.receive_within! : WsClient.Conn, U64 => Try((WsClient.Conn, [Message(Ws.Message), TimedOut]), WsClient.Error)`,
  the next message or `TimedOut` after `ms` milliseconds (`Ws.ReceiveWithin`).
- `WsClient.ops`, the operations as a record (`Ws.Raw`, `Ws.Poll` and
  `Ws.ReceiveWithin`), for code generic over features such as
  `Ws.close_and_wait!`, `Ws.drive!`, `Ws.messages`.
- `WsClient.Errors = [Tcp(IOErr), Connect(IOErr), Entropy(IOErr), Interrupted]`, the
  platform's tags (`IOErr` is `pf.IOErr`); `WsClient.Error = Client.Error(WsClient.Errors)`
  is the whole error union.
- `WsClient.connect`, the `Ws.Connect` feature record.
- `WsClient.transport`, `WsClient.random_bytes!`: the parts.

Every error row is `[Closed(Ws.Closure), Closing, ..e]`: `Closed` once the
connection has ended, `Closing` from `send!` and the other senders after
`close!` while the closing handshake is under way (`receive!` still delivers the
messages on their way, then ends with `Closed`). `opened.extensions` is
`Reported(list)` (this client gives `Reported([])`) or `NotReported`.

## Server

```roc
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	ws: "https://github.com/Karakatiza666/roc-websocket/releases/download/0.0.5/AKLgwxjBQN2XkE4G5sZtzrjPSxhwo6XmJRSPdWhpgVUN.tar.zst",
	cli_ws: "https://github.com/Karakatiza666/roc-basic-cli-websocket/releases/download/0.0.2/A6pcg2YPiT75rhPyftEGQPw9XtqvrLZbmWjruiDY8iHp.tar.zst",
}

import pf.Duration
import pf.OsStr
import pf.Tcp
import cli_ws.WsServer

main! : List(OsStr) => Try({}, _)
main! = |_args| {
	listener = Tcp.listen!("127.0.0.1", 9002, Duration.seconds(5))?
	opened = WsServer.accept!(listener, { protocols: ["echo"] }, {})?
	(conn, message) = opened.conn.receive!()?
	conn2 = conn.send!(message)?
	_ = conn2.receive!()
	Ok({})
}
```

- `WsServer.accept! : Tcp.Listener, Ws.AcceptOptions, WsServer.Options => Try(Ws.Opened(WsServer.Conn), WsServer.Error)`:
  wait for a client, read its upgrade request, answer 101 with the first
  of `protocols` (the server's order of preference) that the client offered.
- `WsServer.read_request! : Tcp.Listener, WsServer.Options => Try(WsServer.Request, WsServer.Error)`,
  the two-step form. `WsServer.Request` is `Server.Request(WsServer.Link, WsServer.Errors)`
  of roc-websocket: `request.upgrade()` is a `Ws.Upgrade` (`resource`, `host`,
  offered `protocols`, `headers` with lowercased names), then
  `request.accept!(options)` or
  `request.refuse!({ status: 404, headers ?: ..., body ?: "..." })`, a
  `Ws.Refusal` with any final status from 200 to 599. The head is read with
  `handshake_timeout`; the request then carries the connection's `read_timeout`
  (`Server.Request.map_link`).
- `WsServer.Options = { accept_timeout ?: [NoTimeout, After(Duration)], handshake_timeout ?: Duration, read_timeout ?: Duration, write_timeout ?: Duration }`
  (defaults `NoTimeout`, 5 s, 30 s, 30 s). The request head must arrive within
  `handshake_timeout`; the connection's reads then use `read_timeout`.
- `WsServer.Conn = Server.Conn(WsServer.Link, WsServer.Errors)`, with the
  methods of `WsClient.Conn`; `WsServer.receive_within!`, `WsServer.ops`
  (`Server.Ops` and `Ws.ReceiveWithin`) and `WsServer.transport`, as for the client.
- `WsServer.Errors = [Tcp(IOErr), Accept(IOErr), ListenerClosed, Interrupted]`:
  `Accept(TimedOut)` is `accept_timeout` passing with no client (the listener
  can accept again). `WsServer.Error = Server.Error(WsServer.Errors)` adds
  `NotUpgrade(Str)` (a request that is not an upgrade, answered with 400, 405,
  426 or 431 already, or no whole request within `handshake_timeout`),
  `InvalidStatus(U16)` and the frame tags.
- `WsServer.serve! : Tcp.Listener, WsServer.Options, WsServer.Service(s), s => (s, Try({}, WsServer.Error))`
  serves one connection at a time with `Ws.drive!`.
  `WsServer.Service(s) = { route : Ws.Upgrade -> WsServer.Route, handlers : Ws.Handlers(s, WsServer.Conn, ...), stop : s -> Bool }`,
  `WsServer.Route = [Accept(Ws.AcceptOptions), Refuse(Ws.Refusal)]`.
- `WsServer.serve_many! : Tcp.Listener, WsServer.Options, WsServer.Service(s), U64, s => (s, Try({}, WsServer.Error))`
  serves several connections in turns, polling each for at most `slice`
  milliseconds (`receive_within!`). basic-cli has no readiness primitive and no
  threads, so a turn over `n` idle connections takes about `n` slices, and a
  new client's handshake holds the turn for up to `handshake_timeout`.

The handlers share one state `s`, and `on_close!` gets the connection as in
`Ws.Handlers` (`on_close! : s, conn, Ws.Closure => Try(s, ...)`). `serve!` and
`serve_many!` drop a client whose handshake fails and go on. Like `Ws.drive!`,
they return the state together with how the call ended: a failure of the
listener is a server that has already served connections, and the state they
left is what the program must save or report, so an error does not lose it.
`(state, ended) = WsServer.serve!(...)`, then `ended?` or a `match`. A
handler's `Err(Closed)` does not end a connection: its remaining messages
are delivered and `on_close!` runs. A reply to a message that arrived in the
same read as the client's Close is sent before the Close is echoed.

basic-cli's Tcp has no close: the socket closes when the last copy of it is
released. Once a call gives `Closed`, drop the connection (and the result of
`refuse!`), and the server closes the TCP connection, as RFC 6455 section
7.1.1 asks. `serve!` and `serve_many!` do.

## Mapping to basic-cli

| roc-websocket | basic-cli |
| --- | --- |
| `Ws.Bytes.write_bytes!` | `Tcp.Connection.write_bytes!`, bounded by `write_timeout` |
| `Ws.Bytes.read_up_to!` `Data(bytes)` | `Tcp.Connection.read_up_to!` |
| `End` | `Err(EndOfInput)` |
| `TimedOut` | `Err(TcpErr(TimedOut))` after `read_timeout` |
| `Ws.Random.random_bytes!` | `Random.seed_u64!`, 8 bytes per call |
| `Ws.Connect` | `Tcp.connect!` with `connect_timeout` |
| `poll!` | `Ok(TimedOut)` when a read times out with no message |
| `Ws.ReceiveWithin.receive_within!(c, ms)` | `Conn.map_link` sets the Tcp read timeout to `ms`, then `poll!`; the connection's own timeout applies again afterwards |

## Timeouts

basic-cli's Tcp has per-connection timeouts: each read or write is bounded as
a whole. A read that times out consumes nothing and the connection keeps
every byte that arrived, so a timeout never loses data, even inside a frame.
`receive!` keeps waiting through `read_timeout`; `poll!` returns `TimedOut`
when it passes with no message, so a short `read_timeout` (say 200 ms) makes
`poll!` a cheap check. `receive_within!(conn, ms)` sets the timeout for
one call (it uses `Client.Conn.map_link` of roc-websocket to give the
link a read connection with that timeout, polls, and puts the original back). `ms` bounds each
read, so a peer that trickles one frame in pieces, each within `ms`, can keep the call
waiting longer than `ms`. A write that times out may have sent a
prefix of its bytes: it is the error `Tcp(TimedOut)` and the connection should
be dropped.

## Limitations

- **One thread, no readiness primitive.** `serve_many!` polls each
  connection in turn; latency grows with the number of idle connections.
- **`ws://` only.** The platform's Tcp has no TLS. `wss://` is `Refused`.
- **No cancellation.** A signal during a call is the error `Interrupted`.
- Randomness comes from `Random.seed_u64!`, the operating system's entropy
  source, as the key and the masks need.

## Changes

### 0.0.2

The subprotocol follows the server's order of preference (roc-websocket 0.0.5).
Built on roc-websocket 0.0.5 (`.roc-version` is `nightly-2026-11-03-34bd006`;
basic-cli 0.26.0 works with it).

Added: the `WsServer` module (see Server): `accept!`, `read_request!`,
`receive_within!`, `ops`, `transport`, `Route`, `Service`, `serve!` and
`serve_many!`, with `examples/server.roc` and `tests/server_test.py`.

Breaking, from roc-websocket 0.0.5. `WsClient` itself did not change; these
affect code that runs handlers over a client connection:

- `Ws.Handlers`: `on_close!` gets the connection, `on_close! : s, c, Ws.Closure => Try(s, ...)`
  (`|state, closure|` becomes `|state, _conn, closure|`).
- `Ws.drive!` returns the state: `(state, ended) = Ws.drive!(WsClient.ops, conn, state, handlers)`,
  then `closure = ended?`. `drive!(...)?` no longer compiles.
- A handler's `Err(Closed)` no longer ends `Ws.drive!`; the rest of the messages
  is delivered and `on_close!` runs.
- The echo of the peer's Close is held until the messages read with it are
  delivered (both roles). An app that never reads again after the last message
  sends no echo.

### 0.0.1

The first release: a client over `pf.Tcp`, for roc-websocket 0.0.4 and
basic-cli 0.26.0, with `receive_within!`. Built with Roc `nightly-2026-10-12-2664a27` (the nightly
basic-cli 0.26.0 is built with) and tested on `nightly-2026-11-01-48d3369` (the pin in `.roc-version`).

## Checks

```sh
ROC=/path/to/roc scripts/all_tests.sh          # fmt, check
ROC=/path/to/roc scripts/all_tests.sh --e2e    # also a live run against tests/echo_server.py
```

`--e2e` also runs `examples/server.roc` (`one`, `many` and `raw` modes) against the
client example and `tests/server_test.py`, raw sockets and, when `$PYTHON` has the
`websockets` package, that independent client:
`PYTHON=/path/to/venv/bin/python ROC=/path/to/roc scripts/all_tests.sh --e2e`.

`examples/client.roc` has `echo [port]` (the Python stdlib test server in `tests/`),
`slow [port]` (`poll!` across a 500 ms read timeout, then `receive_within!`) and `surreal` (JSON `ping` and
`version` RPCs to SurrealDB at `ws://127.0.0.1:8000/rpc`; `--e2e` runs it when
SurrealDB answers on that port).

The release URL (`<hash>` above) is printed by `scripts/bundle.sh 0.0.2` and in the
release notes of each [release](https://github.com/Karakatiza666/roc-basic-cli-websocket/releases).

```sh
ROC=/path/to/roc scripts/bundle.sh 0.0.2  # dist/<hash>.tar.zst and its release URL
ROC=/path/to/roc scripts/test_bundle.sh   # checks the examples against the bundle
```
