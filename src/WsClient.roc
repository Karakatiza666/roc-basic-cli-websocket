import pf.Duration
import pf.Monotonic
import pf.IOErr
import pf.Random
import pf.Tcp
import ws.Ws
import ws.Client
import ws.Handshake

## WebSocket clients for basic-cli 0.26.0, over `pf.Tcp` and the pure client
## of roc-websocket.
##
## Plain `ws://` only: the platform's Tcp has no TLS, so `wss://` is `Refused`.
##
## Timeouts. Every `Tcp` read and write holds a timeout (a `Duration`), set
## when the connection opens. A read that times out consumes nothing and the
## connection keeps every byte it has read, so a timeout never loses data:
## `receive!` keeps waiting through it, and `poll!` returns `TimedOut` when it
## passes with no bytes (an idle deadline: any frame, a Ping included, restarts
## it). `receive_within!` is a total deadline instead. Unlike basic-webserver, the read timeout is
## yours to choose (`read_timeout`, 30 s by default), so a short one makes
## `poll!` a cheap check. A write that times out may have sent a prefix of its
## bytes, so it is the error `Tcp(TimedOut)`: drop the connection.
##
## Randomness. The key and the masks come from `Random.seed_u64!`, the
## operating system's entropy source, 8 bytes per call.
WsClient :: [].{

	## The tags this adapter adds: a Tcp failure, a failure while connecting,
	## a failure to read randomness, and a pending signal (`Interrupted`).
	Errors : [Tcp(IOErr), Connect(IOErr), Entropy(IOErr), Interrupted]

	## The link a connection runs over: the Tcp connection with the timeout
	## of its reads, the same socket with the timeout of its writes, and the
	## total deadline of the call in progress (`receive_within!` sets it; it is
	## `None` otherwise). `read_up_to!` gives `TimedOut` itself once the
	## deadline has passed, and reads with only the time left before then.
	Link : { read : Tcp.Connection, write : Tcp.Connection, deadline : [Within(Monotonic, Duration), None] }

	## A connection. Its methods: `send!`, `receive!`, `poll!`, `close!`,
	## `ping!`, `pong!`, `send_frame!`, `receive_frame!`; each returns the
	## updated connection.
	Conn : Client.Conn(WsClient.Link, WsClient.Errors)

	## Every error of a connection and of `connect!`.
	Error : Client.Error(WsClient.Errors)

	## The platform's own settings, all optional. `connect_timeout` bounds the
	## Tcp connect (5 s), `read_timeout` each read, and so how long `poll!`
	## waits (30 s), `write_timeout` each write as a whole (30 s).
	Options : { connect_timeout ?: Duration, read_timeout ?: Duration, write_timeout ?: Duration }

	## Connect to `request.url` (`ws://host[:port]/path`) and do the handshake,
	## with the default timeouts.
	##
	## ```roc
	## opened = WsClient.connect!({ url: "ws://127.0.0.1:9001/", protocols: ["echo"] })?
	## conn = opened.conn.send!(Text("hi"))?
	## (conn2, reply) = conn.receive!()?
	## ```
	connect! : Ws.ConnectRequest => Try(Ws.Opened(WsClient.Conn), WsClient.Error)
	connect! = |request| WsClient.connect_with!(request, {})

	## `connect!` with the timeouts of `options`.
	##
	## ```roc
	## opened = WsClient.connect_with!({ url: "ws://127.0.0.1:9001/" }, { read_timeout: Duration.millis(200) })?
	## ```
	connect_with! : Ws.ConnectRequest, WsClient.Options => Try(Ws.Opened(WsClient.Conn), WsClient.Error)
	connect_with! = |request, options| {
		url = Handshake.parse_url(request.url).map_err(|BadUrl(why)| Refused(why))?
		if url.secure {
			return Err(Refused("wss:// needs TLS, which basic-cli's Tcp does not have"))
		}
		host = url.host.drop_prefix("[").drop_suffix("]")
		read_timeout = options.?read_timeout ?? Duration.seconds(30)
		write_timeout = options.?write_timeout ?? Duration.seconds(30)
		tcp = match Tcp.connect!(host, url.port, { connect_timeout: options.?connect_timeout ?? Duration.seconds(5), io_timeout: read_timeout }) {
			Ok(conn) => conn
			Err(Interrupted) => return Err(Interrupted)
			Err(TcpErr(err)) => return Err(Connect(err))
		}
		link = { read: tcp, write: tcp.with_timeout(write_timeout), deadline: None }
		Client.open!(WsClient.transport, link, request)
	}

	## The next message, or `TimedOut` when `ms` milliseconds pass first
	## (`Ws.ReceiveWithin`). The connection keeps every byte it has read, so a
	## timeout loses nothing, even inside a frame.
	##
	## `ms` is a total deadline: `TimedOut` comes `ms` milliseconds after the
	## call, whatever arrives meanwhile. Ping, Pong and partial frames do not
	## extend it. The deadline is kept in the link (`Conn.map_link`), and each
	## Tcp read inside the call waits only for the time left. The connection's
	## own `read_timeout` is untouched.
	##
	## ```roc
	## (conn2, got) = WsClient.receive_within!(conn, 250)?
	## ```
	receive_within! : WsClient.Conn, U64 => Try((WsClient.Conn, [Message(Ws.Message), TimedOut]), WsClient.Error)
	receive_within! = |conn, ms| {
		start = Monotonic.now!()
		limited = conn.map_link(|link| { ..link, deadline: Within(start, Duration.millis(ms)) })
		match limited.poll!() {
			Ok((after, got)) => Ok((after.map_link(|link| { ..link, deadline: None }), got))
			Err(err) => Err(err)
		}
	}

	## The operations as a record (`Ws.Raw`, `Ws.Poll` and `Ws.ReceiveWithin`),
	## for code generic over features.
	ops : Ws.Core(WsClient.Conn, Client.Errors(WsClient.Errors), Ws.Ping(WsClient.Conn, Client.Errors(WsClient.Errors), Ws.Pong(WsClient.Conn, Client.Errors(WsClient.Errors), Ws.Frames(WsClient.Conn, Client.Errors(WsClient.Errors), Ws.Poll(WsClient.Conn, Client.Errors(WsClient.Errors), Ws.ReceiveWithin(WsClient.Conn, Client.Errors(WsClient.Errors), {}))))))
	ops = {
		send!: |c, m| c.send!(m),
		receive!: |c| c.receive!(),
		close!: |c, code, reason| c.close!(code, reason),
		ping!: |c, p| c.ping!(p),
		pong!: |c, p| c.pong!(p),
		send_frame!: |c, f| c.send_frame!(f),
		receive_frame!: |c| c.receive_frame!(),
		poll!: |c| c.poll!(),
		receive_within!: |c, ms| WsClient.receive_within!(c, ms),
	}

	## The `Ws.Connect` feature record.
	connect : Ws.Connect(WsClient.Conn, Client.Errors(WsClient.Errors), {})
	connect = { connect!: WsClient.connect! }

	## The byte stream and randomness `Client.open!` needs.
	transport : Client.Transport(WsClient.Link, WsClient.Errors)
	transport = {
		write_bytes!: |link, bytes| match link.write.write_bytes!(bytes) {
			Ok({}) => Ok(link)
			Err(Interrupted) => Err(Interrupted)
			Err(TcpErr(err)) => Err(Tcp(err))
		},
		read_up_to!: |link, n| {
			conn = match link.deadline {
				None => link.read
				Within(start, budget) => {
					left = budget.minus(start.elapsed!())
					if left == Duration.zero {
						return Ok((link, TimedOut))
					}
					link.read.with_timeout(left)
				}
			}
			match conn.read_up_to!(n) {
				Ok(bytes) => Ok((link, Data(bytes)))
				Err(EndOfInput) => Ok((link, End))
				Err(TcpErr(TimedOut)) => Ok((link, TimedOut))
				Err(Interrupted) => Err(Interrupted)
				Err(TcpErr(err)) => Err(Tcp(err))
			}
		},
		random_bytes!: |link, n| {
			bytes = WsClient.random_bytes!(n)?
			Ok((link, bytes))
		},
	}

	## `n` unpredictable bytes from the operating system, 8 per
	## `Random.seed_u64!` call.
	random_bytes! : U64 => Try(List(U8), WsClient.Error)
	random_bytes! = |n| {
		var $out = []
		while $out.len() < n {
			seed = match Random.seed_u64!() {
				Ok(value) => value
				Err(RandomErr(err)) => return Err(Entropy(err))
			}
			var $rest = seed
			for _ in 0.U64..<8 {
				$out = $out.append($rest.to_u8_wrap())
				$rest = $rest // 256
			}
		}
		Ok($out.take_first(n))
	}
}
