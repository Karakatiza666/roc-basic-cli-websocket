import pf.Duration
import pf.IOErr
import pf.Tcp
import ws.Ws
import ws.Server
import ws.Handshake

## WebSocket servers for basic-cli 0.26.0, over `pf.Tcp` and the server driver
## of roc-websocket.
##
## Plain `ws://` only: the platform's Tcp has no TLS.
##
## Timeouts. `Tcp.Listener.accept!` waits `accept_timeout` (no limit by
## default). The request head must arrive within `handshake_timeout` (5 s),
## so a client that connects and says nothing holds the server for at most
## that long. After the handshake each read waits `read_timeout` (30 s):
## `receive!` keeps waiting through it, `poll!` gives `TimedOut`, and
## `receive_within!` sets it for one call. A read that times out consumes
## nothing. A write that times out may have sent a prefix of its bytes, so it
## is the error `Tcp(TimedOut)`: drop the connection.
##
## Closing. basic-cli's Tcp has no close: a socket closes when the last
## reference to it is released. Once a call gives `Closed`, drop every copy of
## the connection (and of the link from `refuse!`), and the server closes the
## TCP connection, as RFC 6455 section 7.1.1 asks of it. `serve!` and
## `serve_many!` do this.
##
## Serving. `serve!` takes one connection at a time and runs `Ws.Handlers`
## over it with `Ws.drive!`. `serve_many!` holds several and polls each in
## turn with a short read timeout: basic-cli has no readiness primitive and no
## threads, so a turn over `n` idle connections takes about `n` times `slice`.
WsServer :: [].{

	## The tags this adapter adds: a Tcp failure on a connection, a failure
	## of `Tcp.Listener.accept!` (`Accept(TimedOut)` when `accept_timeout`
	## passed with no client; the listener can accept again), the listener
	## closed, and a pending signal (`Interrupted`).
	Errors : [Tcp(IOErr), Accept(IOErr), ListenerClosed, Interrupted]

	## The link a connection runs over: the Tcp connection with the timeout
	## of its reads, and the same socket with the timeout of its writes.
	Link : { read : Tcp.Connection, write : Tcp.Connection }

	## A server connection. Its methods: `send!`, `receive!`, `poll!`,
	## `close!`, `ping!`, `pong!`, `send_frame!`, `receive_frame!`, `link`,
	## `map_link`; each returns the updated connection.
	Conn : Server.Conn(WsServer.Link, WsServer.Errors)

	## Every error of a connection and of `accept!`.
	Error : Server.Error(WsServer.Errors)

	## The platform's own settings, all optional. `accept_timeout` bounds the
	## wait for a client (`NoTimeout` by default), `handshake_timeout` the
	## reads of the request head (5 s), `read_timeout` each later read, and so
	## how long `poll!` waits (30 s), `write_timeout` each write as a whole
	## (30 s).
	Options : { accept_timeout ?: [NoTimeout, After(Duration)], handshake_timeout ?: Duration, read_timeout ?: Duration, write_timeout ?: Duration }

	## What a server does with a request: accept it with options (the
	## subprotocols it supports, the largest message) or refuse it.
	Route : [Accept(Ws.AcceptOptions), Refuse(Server.Refusal)]

	## A service for `serve!` and `serve_many!`: how to route each request,
	## the handlers of each accepted connection, all sharing the state `s`,
	## and when to stop: once `stop(s)` holds, no new client is accepted and
	## the call returns when the connections it holds have ended.
	Service(s) : {
		route : Handshake.Upgrade -> WsServer.Route,
		handlers : Ws.Handlers(s, WsServer.Conn, Server.Errors(WsServer.Errors)),
		stop : s -> Bool,
	}

	## An upgrade request read from a client and validated, not answered yet,
	## from `WsServer.read_request!`.
	Request :: { request : Server.Request(WsServer.Link, WsServer.Errors), read : Tcp.Connection }.{

		## The request: its resource, `Host`, the offered subprotocols and
		## every header.
		upgrade : WsServer.Request -> Handshake.Upgrade
		upgrade = |r| r.request.upgrade()

		## Accept the upgrade (`Server.Request.accept!`). The connection's
		## reads then use `read_timeout`.
		accept! : WsServer.Request, Ws.AcceptOptions => Try(Ws.Opened(WsServer.Conn), WsServer.Error)
		accept! = |r, options| match r.request.accept!(options) {
			Ok(opened) => Ok({ ..opened, conn: opened.conn.map_link(|link| { ..link, read: r.read }) })
			Err(err) => Err(err)
		}

		## Refuse the upgrade with a status from 400 to 599
		## (`Server.Request.refuse!`). The Tcp connection closes when the
		## result is dropped.
		refuse! : WsServer.Request, Server.Refusal => Try({}, WsServer.Error)
		refuse! = |r, refusal| match r.request.refuse!(refusal) {
			Ok(_) => Ok({})
			Err(err) => Err(err)
		}
	}

	## Wait for a client on `listener` and read its upgrade request, for an
	## application that looks at the request before it accepts or refuses.
	##
	## ```roc
	## request = WsServer.read_request!(listener, {})?
	## if request.upgrade().resource == "/echo" {
	##     opened = request.accept!({ protocols: ["echo"] })?
	##     ...
	## } else {
	##     request.refuse!({ status: 404, body: "no such endpoint" })?
	## }
	## ```
	read_request! : Tcp.Listener, WsServer.Options => Try(WsServer.Request, WsServer.Error)
	read_request! = |listener, options| {
		tcp = match listener.accept!({ accept_timeout: options.?accept_timeout ?? NoTimeout, io_timeout: options.?read_timeout ?? Duration.seconds(30) }) {
			Ok(conn) => conn
			Err(Closed) => return Err(ListenerClosed)
			Err(Interrupted) => return Err(Interrupted)
			Err(TcpErr(err)) => return Err(Accept(err))
		}
		link = {
			read: tcp.with_timeout(options.?handshake_timeout ?? Duration.seconds(5)),
			write: tcp.with_timeout(options.?write_timeout ?? Duration.seconds(30)),
		}
		match Server.read_request!(WsServer.transport, link) {
			Ok(request) => Ok(WsServer.Request.{ request, read: tcp })
			Err(err) => Err(err)
		}
	}

	## Wait for a client, read its request and accept it with `accept`.
	##
	## ```roc
	## listener = Tcp.listen!("127.0.0.1", 9002, Duration.seconds(5))?
	## opened = WsServer.accept!(listener, { protocols: ["echo"] }, {})?
	## (conn, message) = opened.conn.receive!()?
	## ```
	accept! : Tcp.Listener, Ws.AcceptOptions, WsServer.Options => Try(Ws.Opened(WsServer.Conn), WsServer.Error)
	accept! = |listener, accept, options| {
		request = WsServer.read_request!(listener, options)?
		request.accept!(accept)
	}

	## The next message, or `TimedOut` when `ms` milliseconds pass first
	## (`Ws.ReceiveWithin`), as `WsClient.receive_within!` does: the Tcp read
	## timeout is `ms` for this call, and `ms` bounds each read.
	receive_within! : WsServer.Conn, U64 => Try((WsServer.Conn, [Message(Ws.Message), TimedOut]), WsServer.Error)
	receive_within! = |conn, ms| {
		own = conn.link().read
		shortened = conn.map_link(|link| { ..link, read: own.with_timeout(Duration.millis(ms)) })
		match shortened.poll!() {
			Ok((after, got)) => Ok((after.map_link(|link| { ..link, read: own }), got))
			Err(err) => Err(err)
		}
	}

	## The operations as a record (`Server.Ops` and `Ws.ReceiveWithin`), for
	## code generic over features.
	ops : Ws.Core(WsServer.Conn, Server.Errors(WsServer.Errors), Ws.Ping(WsServer.Conn, Server.Errors(WsServer.Errors), Ws.Pong(WsServer.Conn, Server.Errors(WsServer.Errors), Ws.Frames(WsServer.Conn, Server.Errors(WsServer.Errors), Ws.Poll(WsServer.Conn, Server.Errors(WsServer.Errors), Ws.ReceiveWithin(WsServer.Conn, Server.Errors(WsServer.Errors), {}))))))
	ops = {
		send!: |c, m| c.send!(m),
		receive!: |c| c.receive!(),
		close!: |c, code, reason| c.close!(code, reason),
		ping!: |c, p| c.ping!(p),
		pong!: |c, p| c.pong!(p),
		send_frame!: |c, f| c.send_frame!(f),
		receive_frame!: |c| c.receive_frame!(),
		poll!: |c| c.poll!(),
		receive_within!: |c, ms| WsServer.receive_within!(c, ms),
	}

	## Serve one connection at a time: accept a client, route its request,
	## and run `service.handlers` over the connection with `Ws.drive!` until
	## it closes; then the next client. Returns the state once `service.stop`
	## holds after a connection, or at the first error of the listener.
	##
	## A client whose handshake fails, or whose connection fails, is dropped
	## and the next one accepted. `Ws.drive!` gives no state with its error,
	## so a connection that fails leaves the state as it was before that
	## connection.
	serve! : Tcp.Listener, WsServer.Options, WsServer.Service(s), s => Try(s, WsServer.Error)
	serve! = |listener, options, service, state| {
		var $s = state
		while !(service.stop)($s) {
			match WsServer.read_request!(listener, options) {
				Ok(request) =>
					match routed!(request, (service.route)(request.upgrade())) {
						Ok(Opened(conn)) =>
							match Ws.drive!(WsServer.ops, conn, $s, service.handlers) {
								Ok(after) => {
									$s = after
								}
								Err(_) => {}
							}
						Ok(Refused) => {}
						Err(_) => {}
					}
				Err(ListenerClosed) => return Err(ListenerClosed)
				Err(Interrupted) => return Err(Interrupted)
				Err(Accept(TimedOut)) => {}
				Err(Accept(err)) => return Err(Accept(err))
				Err(_) => {}
			}
		}
		Ok($s)
	}

	## Serve several connections at once, in turns. Each turn accepts a new
	## client if one is waiting (within `slice` while connections are open;
	## with `accept_timeout` when none are), then polls each connection for
	## at most `slice` (10 ms by default) and runs its handler on a message.
	## A connection leaves the turn when it closes (`on_close!`).
	##
	## Latency grows with the number of idle connections, about `slice` each:
	## basic-cli has no readiness primitive. The handshake of a new client
	## holds the turn for up to `handshake_timeout`.
	##
	## A handler error `Closed` (a reply to a message that arrived with the
	## client's Close) keeps the connection as it was before the call, so the
	## rest of its messages and `on_close!` still come. Another handler error
	## closes the connection with 1011. A connection that fails at the
	## transport ends with `on_close!` of `Ws.dropped`.
	serve_many! : Tcp.Listener, WsServer.Options, WsServer.Service(s), U64, s => Try(s, WsServer.Error)
	serve_many! = |listener, options, service, slice, state| {
		var $s = state
		var $conns = []
		var $accepting = Bool.True
		while $accepting or !$conns.is_empty() {
			if $accepting and (service.stop)($s) {
				$accepting = Bool.False
			}
			if $accepting {
				wait = if ($conns.is_empty()) options.?accept_timeout ?? NoTimeout else After(Duration.millis(slice))
				match WsServer.read_request!(listener, { ..options, accept_timeout: wait }) {
					Ok(request) =>
						match routed!(request, (service.route)(request.upgrade())) {
							Ok(Opened(conn)) =>
								match (service.handlers.on_open!)($s, conn) {
									Ok((s1, c1)) => {
										$s = s1
										$conns = $conns.append(c1)
									}
									Err(_) => {}
								}
							Ok(Refused) => {}
							Err(_) => {}
						}
					Err(ListenerClosed) => return Err(ListenerClosed)
					Err(Interrupted) => return Err(Interrupted)
					Err(Accept(TimedOut)) => {}
					Err(Accept(err)) => return Err(Accept(err))
					Err(_) => {}
				}
			}
			var $kept = []
			for conn in $conns {
				match WsServer.receive_within!(conn, slice) {
					Ok((polled, TimedOut)) => {
						$kept = $kept.append(polled)
					}
					Ok((polled, Message(m))) =>
						match (service.handlers.on_message!)($s, polled, m) {
							Ok((s1, c1)) => {
								$s = s1
								$kept = $kept.append(c1)
							}
							Err(Closed(_)) => {
								$kept = $kept.append(polled)
							}
							Err(_) =>
								match polled.close!(1011, "") {
									Ok(closing) => {
										$kept = $kept.append(closing)
									}
									Err(_) => {
										$s = closed!(service, $s, Ws.dropped)
									}
								}
						}
					Err(Closed(closure)) => {
						$s = closed!(service, $s, closure)
					}
					Err(_) => {
						$s = closed!(service, $s, Ws.dropped)
					}
				}
			}
			$conns = $kept
		}
		Ok($s)
	}

	## The byte stream `Server.read_request!` needs.
	transport : Server.Transport(WsServer.Link, WsServer.Errors)
	transport = {
		write_bytes!: |link, bytes| match link.write.write_bytes!(bytes) {
			Ok({}) => Ok(link)
			Err(Interrupted) => Err(Interrupted)
			Err(TcpErr(err)) => Err(Tcp(err))
		},
		read_up_to!: |link, n| match link.read.read_up_to!(n) {
			Ok(bytes) => Ok((link, Data(bytes)))
			Err(EndOfInput) => Ok((link, End))
			Err(TcpErr(TimedOut)) => Ok((link, TimedOut))
			Err(Interrupted) => Err(Interrupted)
			Err(TcpErr(err)) => Err(Tcp(err))
		},
	}
}

## Answer a request as `route` says.
routed! : WsServer.Request, WsServer.Route => Try([Opened(WsServer.Conn), Refused], WsServer.Error)
routed! = |request, route| match route {
	Accept(options) =>
		match request.accept!(options) {
			Ok(opened) => Ok(Opened(opened.conn))
			Err(err) => Err(err)
		}
	Refuse(refusal) =>
		match request.refuse!(refusal) {
			Ok({}) => Ok(Refused)
			Err(err) => Err(err)
		}
}

## The state after `on_close!`, or the state before it when it fails.
closed! : WsServer.Service(s), s, Ws.Closure => s
closed! = |service, state, closure| match (service.handlers.on_close!)(state, closure) {
	Ok(after) => after
	Err(_) => state
}
