## A command-line WebSocket client.
##
##   client echo [port]   talks to an echo server on 127.0.0.1 (tests/echo_server.py,
##                        port 9001 by default) and reports each step.
##   client slow [port]   asks the echo server to wait 3 s with a 500 ms read timeout:
##                        `poll!` gives TimedOut, then the reply, with nothing lost; then
##                        `receive_within!` with 200 ms and with 5000 ms.
##   client surreal       sends JSON `ping` and `version` RPCs to SurrealDB at
##                        ws://127.0.0.1:8000/rpc.
app [main!] {
	cli_ws: "../src/main.roc",
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	ws: "https://github.com/Karakatiza666/roc-websocket/releases/download/0.0.5/AKLgwxjBQN2XkE4G5sZtzrjPSxhwo6XmJRSPdWhpgVUN.tar.zst",
}

import pf.Duration
import pf.OsStr
import pf.Stdout
import pf.Stderr
import ws.Ws
import cli_ws.WsClient

main! : List(OsStr) => Try({}, _)
main! = |args| {
	words = args.map(|a| a.display())
	result =
		match words {
			["echo"] => echo!("9001")
			["echo", port] => echo!(port)
			["slow"] => slow!("9001")
			["slow", port] => slow!(port)
			["surreal"] => surreal!({})
			_ => Ok("usage: client echo [port] | slow [port] | surreal\n")
		}
	match result {
		Ok(text) => {
			Stdout.write!(text)?
			Ok({})
		}
		Err(err) => {
			Stderr.line!("WebSocket failed: ${Str.inspect(err)}")?
			Err(Exit(1))
		}
	}
}

show : Ws.Message -> Str
show = |message| match message {
	Text(s) => "Text(\"${s}\")"
	Binary(b) => "Binary(${b.len().to_str()} bytes)"
}

## Each step of a session with the test echo server, as lines of text.
echo! : Str => Try(Str, WsClient.Error)
echo! = |port| {
	opened = WsClient.connect!({ url: "ws://127.0.0.1:${port}/chat?room=1", protocols: ["chat", "echo"] })?
	extensions =
		match opened.extensions {
			Reported(list) => "${list.len().to_str()} reported"
			NotReported => "not reported"
		}
	var $lines = ["connected, subprotocol \"${opened.protocol}\", extensions ${extensions}"]

	# Each call returns the updated connection.
	exchange! = |conn, message| {
		sent = conn.send!(message)?
		sent.receive!()
	}

	(c1, m1) = exchange!(opened.conn, Text("hello from basic-cli"))?
	$lines = $lines.append("echo: ${show(m1)}")
	(c2, m2) = exchange!(c1, Binary([1, 2, 3, 250]))?
	$lines = $lines.append("echo: ${show(m2)}")
	(c3, m3) = exchange!(c2, Text("fragment-me"))?
	$lines = $lines.append("assembled: ${show(m3)}")
	(c4, m4) = exchange!(c3, Text("ping-me"))?
	$lines = $lines.append("after a server ping: ${show(m4)}")
	(c5, m5) = exchange!(c4, Text("big:70000"))?
	$lines = $lines.append("big: ${show(m5)}")

	# Our own fragmented message, sent frame by frame.
	c6 = c5.send_frame!({ fin: Bool.False, opcode: Text, payload: "sent in ".to_utf8() })?
	c7 = c6.send_frame!({ fin: Bool.True, opcode: Continuation, payload: "two frames".to_utf8() })?
	(c8, m6) = c7.receive!()?
	$lines = $lines.append("echo of fragments: ${show(m6)}")

	c9 = c8.ping!("roc".to_utf8())?
	(c10, pong) = c9.receive_frame!()?
	$lines = $lines.append("pong frame: ${Str.inspect(pong.opcode)} \"${Str.from_utf8(pong.payload) ?? "?"}\"")

	# close! starts the close; receive! finishes it.
	c11 = c10.close!(1000, "done")?
	# Until the close completes, a send gives Closing.
	closing = match c11.send!(Text("late")) {
		Err(Closing) => "send while closing: Closing"
		_ => "send while closing: unexpected"
	}
	$lines = $lines.append(closing)
	closed = match c11.receive!() {
		Err(Closed(c)) => "closed: ${Str.inspect(c)}"
		Ok((_, m)) => "unexpected message ${show(m)}"
		Err(other) => return Err(other)
	}
	$lines = $lines.append(closed)

	# A second connection, closed by the server.
	second = WsClient.connect!({ url: "ws://127.0.0.1:${port}/" })?
	s1 = second.conn.send!(Text("close-me"))?
	ended = match s1.receive!() {
		Err(Closed(c)) => "server closed: ${Str.inspect(c)}"
		Ok((_, m)) => "unexpected message ${show(m)}"
		Err(other) => return Err(other)
	}
	$lines = $lines.append(ended)
	Ok("${Str.join_with($lines, "\n")}\n")
}

## A JSON `ping` RPC to SurrealDB, through the generic helpers of `Ws` over
## the adapter's operations record.
surreal! : {} => Try(Str, WsClient.Error)
surreal! = |{}| {
	opened = WsClient.connect!({ url: "ws://127.0.0.1:8000/rpc", protocols: ["json"] })?
	ops = WsClient.ops
	c1 = (ops.send!)(opened.conn, Text("{\"id\":1,\"method\":\"ping\"}"))?
	(c2, reply) = (ops.receive!)(c1)?
	c3 = (ops.send!)(c2, Text("{\"id\":2,\"method\":\"version\"}"))?
	(c4, version) = (ops.receive!)(c3)?
	closure = Ws.close_and_wait!(ops, c4, 1000, "")?
	Ok("subprotocol \"${opened.protocol}\"\nping reply: ${show(reply)}\nversion reply: ${show(version)}\nclosed: ${Str.inspect(closure)}\n")
}

## A reply slower than the read timeout: `poll!` gives `TimedOut`, the
## connection keeps its state, and a later `poll!` gets the reply.
slow! : Str => Try(Str, WsClient.Error)
slow! = |port| {
	opened = WsClient.connect_with!({ url: "ws://127.0.0.1:${port}/" }, { read_timeout: Duration.millis(500) })?
	c1 = opened.conn.send!(Text("sleep:3"))?
	(c2, first) = c1.poll!()?
	var $conn = c2
	var $polls = 1.U64
	var $last = first
	while $last == TimedOut {
		(next, got) = $conn.poll!()?
		$conn = next
		$last = got
		$polls = $polls + 1
	}

	# A per-call timeout: receive_within! shortens the read timeout for one call.
	c3 = $conn.send!(Text("sleep:1"))?
	(c4, short) = WsClient.receive_within!(c3, 200)?
	(c5, long) = (WsClient.ops.receive_within!)(c4, 5000)?
	_ = Ws.close_and_wait!(WsClient.ops, c5, 1000, "")?
	Ok("first poll: ${Str.inspect(first)}\ntimed out polls before the reply: ${($polls - 1).to_str()}\nreply: ${Str.inspect($last)}\nreceive_within 200 ms: ${Str.inspect(short)}\nreceive_within 5000 ms: ${Str.inspect(long)}\n")
}
