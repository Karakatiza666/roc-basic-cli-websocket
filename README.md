# roc-basic-cli-websocket

A WebSocket client for [basic-cli](https://github.com/roc-lang/basic-cli)
0.26.0, built on [roc-websocket](https://github.com/Karakatiza666/roc-websocket).
Use it in a command-line program to talk to a WebSocket server.

```roc
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	ws: "https://github.com/Karakatiza666/roc-websocket/releases/download/0.0.3/FvsFHmH7m6LoMumXLxEHEfUoApGWdkgoFshfYEctaMNM.tar.zst",
	cli_ws: "https://github.com/Karakatiza666/roc-basic-cli-websocket/releases/download/0.0.1/3XaiwS2fm9FQz65f52HL6EYfbBR8egmVj6bMZkxofXzR.tar.zst",
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
- `WsClient.ops : Client.Ops(WsClient.Link, WsClient.Errors)`, the same as a
  record (`Ws.Raw` and `Ws.Poll`), for code generic over features such as
  `Ws.close_and_wait!`, `Ws.drive!`, `Ws.messages`.
- `WsClient.Errors = [Tcp(IOErr), Connect(IOErr), Entropy(IOErr), Interrupted]`, the
  platform's tags (`IOErr` is `pf.IOErr`); `WsClient.Error = Client.Error(WsClient.Errors)`
  is the whole error union.
- `WsClient.dial`, the `Ws.Connect` feature record.
- `WsClient.transport`, `WsClient.random_bytes!`: the parts.

Every error row is `[Closed(Ws.Closure), Closing, ..e]`: `Closed` once the
connection has ended, `Closing` from `send!` and the other senders after
`close!` while the closing handshake is under way (`receive!` still delivers the
messages on their way, then ends with `Closed`). `opened.extensions` is
`Reported(list)` (this client gives `Reported([])`) or `NotReported`.

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

## Timeouts

basic-cli's Tcp has per-connection timeouts: each read or write is bounded as
a whole. A read that times out consumes nothing and the connection keeps
every byte that arrived, so a timeout never loses data, even inside a frame.
`receive!` keeps waiting through `read_timeout`; `poll!` returns `TimedOut`
when it passes with no message, so a short `read_timeout` (say 200 ms) makes
`poll!` a cheap check. The timeout is fixed per connection; it is not a
per-call argument (see Changes). A write that times out may have sent a
prefix of its bytes: it is the error `Tcp(TimedOut)` and the connection should
be dropped.

## Limitations

- **Client only.** basic-cli has `Tcp.listen!`, but roc-websocket's server side
  is not part of this package.
- **`ws://` only.** The platform's Tcp has no TLS. `wss://` is `Refused`.
- **No `receive_within!`.** The read timeout is set when connecting.
- **No cancellation.** A signal during a call is the error `Interrupted`.
- Randomness comes from `Random.seed_u64!`, the operating system's entropy
  source, as the key and the masks need.

## Changes

### 0.0.1

The first release: a client over `pf.Tcp`, for roc-websocket 0.0.3 and
basic-cli 0.26.0. Built with Roc `nightly-2026-10-12-2664a27` (the nightly
basic-cli 0.26.0 is built with) and tested on `nightly-2026-10-31-f7bef6b`.

## Checks

```sh
ROC=/path/to/roc scripts/all_tests.sh          # fmt, check
ROC=/path/to/roc scripts/all_tests.sh --e2e    # also a live run against tests/echo_server.py
```

`examples/client.roc` has `echo [port]` (the Python stdlib test server in `tests/`),
`slow [port]` (`poll!` across a 500 ms read timeout) and `surreal` (JSON `ping` and
`version` RPCs to SurrealDB at `ws://127.0.0.1:8000/rpc`; `--e2e` runs it when
SurrealDB answers on that port).

The release URL (`<hash>` above) is printed by `scripts/bundle.sh 0.0.1` and in the
release notes of each [release](https://github.com/Karakatiza666/roc-basic-cli-websocket/releases).

```sh
ROC=/path/to/roc scripts/bundle.sh 0.0.1  # dist/<hash>.tar.zst and its release URL
ROC=/path/to/roc scripts/test_bundle.sh   # checks the examples against the bundle
```
