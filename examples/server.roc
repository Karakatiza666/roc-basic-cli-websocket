## A command-line WebSocket server on 127.0.0.1.
##
##   server one <port> <n>    serves one connection at a time (`WsServer.serve!`)
##   server many <port> <n>   serves several at once, in turns (`WsServer.serve_many!`)
##   server raw <port>        one connection with the two-step form and the methods
##   server deadline <port>   one connection: `receive_within!` of 3000 ms twice (for
##                            tests/ping_client.py, which pings every second and sends
##                            one message 4.5 s after it connects), then a close
##
## Each stops after `n` connections have closed. Port 0 asks the system for a
## free port; the first line printed is `listening on <port>`. Routes:
## `/versions...` accepts the subprotocols `chat` and `v2`, in that order;
## `/private...` is refused with 403, `/missing...` with 404; anything else is
## accepted, with the subprotocols `echo` and `chat` (the first of these that
## the client offered) and messages of at most 1 MiB.
##
## Every connection first gets a Ping "hello-ping". Each message is echoed,
## except these text messages, as tests/echo_server.py answers them:
##   "fragment-me"  the reply "fragmented reply" in 3 fragments with a Ping between
##   "ping-me"      a Ping "are you there", then the reply "pinged"
##   "close-me"     the server closes with 4000 "server says bye"
##   "big:<n>"      n bytes of 'x', binary
##   "stats"        the number of messages and closed connections so far
## Each closure is printed as a line `closed: <closure>`.
app [main!] {
	cli_ws: "../src/main.roc",
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.27.0/9yjxqdGTP4xSpSEmDazwTmRsehfRZzA19pwEKkR6fj1g.tar.zst",
	ws: "https://github.com/Karakatiza666/roc-websocket/releases/download/0.0.6/6rcitHh7bVV7D4A2aubD6H6yLHUgtXLi6jRwxjomSwVv.tar.zst",
}

import pf.Duration
import pf.OsStr
import pf.Stdout
import pf.Monotonic
import pf.Stderr
import pf.Tcp
import ws.Ws
import cli_ws.WsServer

State : { messages : U64, closed : U64, limit : U64 }

main! : List(OsStr) => Try({}, _)
main! = |args| {
	words = args.map(|a| a.display())
	(mode, port_text, n_text) = match words {
		[m, p, n] => (m, p, n)
		[m, p] => (m, p, "1")
		_ => {
			Stderr.line!("usage: server one|many <port> <n> | raw <port>")?
			return Err(Exit(2))
		}
	}
	port = U16.from_str(port_text) ?? 9002
	limit = U64.from_str(n_text) ?? 1
	listener = Tcp.listen!("127.0.0.1", port, Duration.seconds(5))?
	# Port 0 asks the system for a free one.
	Stdout.line!("listening on ${listener.local_port!()?.to_str()}")?
	start = { messages: 0, closed: 0, limit }
	(s, ended) = match mode {
		"one" => WsServer.serve!(listener, {}, service, start)
		"many" => WsServer.serve_many!(listener, {}, service, 10, start)
		"raw" => match raw!(listener) {
			Ok(done) => (done, Ok({}))
			Err(err) => (start, Err(err))
		}
		"deadline" => match deadline!(listener) {
			Ok({}) => (start, Ok({}))
			Err(err) => (start, Err(err))
		}
		_ => (start, Ok({}))
	}
	# The state comes with an error too.
	Stdout.line!("done: ${s.messages.to_str()} messages, ${s.closed.to_str()} connections")?
	match ended {
		Ok({}) => Ok({})
		Err(err) => {
			Stderr.line!("server failed: ${Str.inspect(err)}")?
			Err(Exit(1))
		}
	}
}

route : Ws.Upgrade -> WsServer.Route
route = |upgrade|
	if upgrade.resource.starts_with("/private") {
		Refuse({ status: 403, body: "no access to ${upgrade.resource}" })
	} else if upgrade.resource.starts_with("/versions") {
		Accept({ protocols: ["chat", "v2"] })
	} else if upgrade.resource.starts_with("/missing") {
		Refuse({ status: 404, headers: [("X-Route", "none")], body: "no endpoint at ${upgrade.resource}" })
	} else {
		Accept({ protocols: ["echo", "chat"], max_message: 1024 * 1024 })
	}

service : WsServer.Service(State)
service = {
	route,
	handlers: {
		on_open!: |s, conn| match conn.ping!("hello-ping".to_utf8()) {
			Ok(pinged) => Ok((s, pinged))
			Err(err) => Err(err)
		},
		on_message!: |s, conn, message| match reply!(conn, message, s) {
			Ok(after) => Ok(({ ..s, messages: s.messages + 1 }, after))
			Err(err) => Err(err)
		},
		on_close!: |s, _conn, closure| {
			_ = Stdout.line!("closed: ${Str.inspect(closure)}")
			Ok({ ..s, closed: s.closed + 1 })
		},
	},
	stop: |s| s.closed >= s.limit,
}

## Answer one message.
reply! : WsServer.Conn, Ws.Message, State => Try(WsServer.Conn, WsServer.Error)
reply! = |conn, message, s| match message {
	Text("fragment-me") => {
		c1 = conn.send_frame!({ fin: Bool.False, opcode: Text, payload: "fragmented ".to_utf8() })?
		c2 = c1.ping!("mid".to_utf8())?
		c3 = c2.send_frame!({ fin: Bool.False, opcode: Continuation, payload: "re".to_utf8() })?
		c3.send_frame!({ fin: Bool.True, opcode: Continuation, payload: "ply".to_utf8() })
	}
	Text("ping-me") => {
		c1 = conn.ping!("are you there".to_utf8())?
		c1.send!(Text("pinged"))
	}
	Text("close-me") => conn.close!(4000, "server says bye")
	Text("stats") => conn.send!(Text("${s.messages.to_str()} messages, ${s.closed.to_str()} closed"))
	Text(text) if text.starts_with("big:") => {
		n = U64.from_str(text.drop_prefix("big:")) ?? 0
		conn.send!(Binary(List.repeat('x', n)))
	}
	other => conn.send!(other)
}

## One connection with the two-step form and the connection's methods: read
## the request, print it, accept it, echo until the client closes.
raw! : Tcp.Listener => Try(State, WsServer.Error)
raw! = |listener| {
	request = WsServer.read_request!(listener, { read_timeout: Duration.millis(200) })?
	upgrade = request.upgrade()
	_ = Stdout.line!("request: ${upgrade.resource} offering ${Str.inspect(upgrade.protocols)}")
	opened = request.accept!({ protocols: upgrade.protocols.take_last(1) })?
	_ = Stdout.line!("subprotocol: \"${opened.protocol}\"")
	var $conn = opened.conn
	var $count = 0.U64
	var $idle = 0.U64
	while Bool.True {
		match $conn.poll!() {
			Ok((next, Message(m))) => {
				$conn = next.send!(m)?
				$count = $count + 1
			}
			Ok((next, TimedOut)) => {
				$conn = next
				$idle = $idle + 1
			}
			Err(Closed(closure)) => {
				_ = Stdout.line!("closed: ${Str.inspect(closure)}, ${$idle.to_str()} idle polls")
				return Ok({ messages: $count, closed: 1, limit: 1 })
			}
			Err(err) => return Err(err)
		}
	}
}

## One connection and two `receive_within!` calls of 3000 ms. The peer pings
## every second, so the first ends in `TimedOut` after about 3 s (the Pings do
## not extend it), and the second gets the message the peer sends in between.
deadline! : Tcp.Listener => Try({}, WsServer.Error)
deadline! = |listener| {
	opened = WsServer.accept!(listener, {}, {})?
	start = Monotonic.now!()
	(c1, first) = WsServer.receive_within!(opened.conn, 3000)?
	_ = Stdout.line!("first: ${Str.inspect(first)} after ${start.elapsed!().to_millis().to_str()} ms")
	second_start = Monotonic.now!()
	(c2, second) = WsServer.receive_within!(c1, 3000)?
	_ = Stdout.line!("second: ${Str.inspect(second)} after ${second_start.elapsed!().to_millis().to_str()} ms")
	closure = Ws.close_and_wait!(WsServer.ops, c2, 1000, "")?
	_ = Stdout.line!("closed: ${Str.inspect(closure)}")
	Ok({})
}
