#!/usr/bin/env bash
# The local checks. Usage: ROC=/path/to/roc scripts/all_tests.sh [--e2e]
# With --e2e, also builds examples/client.roc, starts tests/echo_server.py on
# port 9001 and runs the client against it (needs python3). When SurrealDB
# answers on 127.0.0.1:8000 (root/root, any auth), also runs `client surreal`.
# It also runs tests/ping_server.py against `client deadline` (a total
# receive_within! deadline against a peer that pings every second), and
# `server deadline` against tests/ping_client.py.
# Then builds examples/server.roc and runs, against each of its modes, the
# client example and tests/server_test.py, each on a port the system chooses. $PYTHON (default
# python3) runs the tests; with the `websockets` package installed in it, they
# include the checks through that independent client.
set -euo pipefail
ROC="${ROC:-roc}"
cd "$(dirname "$0")/.."

"$ROC" version
"$ROC" fmt --check src examples
"$ROC" check src/main.roc
for f in examples/*.roc; do
	"$ROC" check "$f"
done

if [[ "${1:-}" == "--e2e" ]]; then
	out="$PWD/.cache/e2e"
	mkdir -p "$out"
	PYTHON="${PYTHON:-python3}"
	"$ROC" build examples/client.roc --output="$out/client"
	"$ROC" build examples/server.roc --output="$out/server"
	python3 -I tests/echo_server.py 9001 2>"$out/server.log" &
	server=$!
	servers=("$server")
	trap 'kill "${servers[@]}" 2>/dev/null || true' EXIT
	sleep 1
	reply="$("$out/client" echo 9001)"
	echo "$reply"
	grep -q 'closed: { by: Us, clean: True, code: 1000' <<<"$reply"
	grep -q 'server closed: { by: Peer, clean: True, code: 4000' <<<"$reply"
	grep -q 'big: Binary(70000 bytes)' <<<"$reply"
	slow="$("$out/client" slow 9001)"
	echo "$slow"
	grep -q 'first poll: TimedOut' <<<"$slow"
	grep -q 'reply: Message(Text("woke up"))' <<<"$slow"
	grep -q 'receive_within 200 ms: TimedOut' <<<"$slow"
	grep -q 'receive_within 5000 ms: Message(Text("woke up"))' <<<"$slow"
	# A total deadline: the peer pings every second and sends no data, so
	# receive_within!(conn, 3000) must give TimedOut after about 3 s, and a
	# message that arrives before the deadline is still delivered.
	in_range() { [[ $1 =~ ^[0-9]+$ ]] && ((10#$1 >= $2 && 10#$1 <= $3)); }
	python3 -I tests/ping_server.py 9003 2>"$out/ping_server.log" &
	servers+=("$!")
	sleep 1
	deadline="$("$out/client" deadline 9003)"
	echo "$deadline"
	grep -q '^first: TimedOut after ' <<<"$deadline"
	in_range "$(sed -n 's/^first: TimedOut after \([0-9]*\) ms$/\1/p' <<<"$deadline")" 2500 5000
	grep -q '^second: Message(Text("data")) after ' <<<"$deadline"
	in_range "$(sed -n 's/^second: .* after \([0-9]*\) ms$/\1/p' <<<"$deadline")" 1000 2900
	kill "${servers[-1]}"
	if (: >/dev/tcp/127.0.0.1/8000) 2>/dev/null; then
		surreal="$("$out/client" surreal)"
		echo "$surreal"
		grep -q 'ping reply' <<<"$surreal"
		grep -q 'version reply: Text("{\"id\":2,\"result\":\"surrealdb-' <<<"$surreal"
	else
		echo "SurrealDB not on 127.0.0.1:8000: skipped"
	fi

	# Start the Roc server in a mode on a free port: its log is $out/<log>.log
	# and its port $port. (A server closes TCP first, so its port is left in
	# TIME_WAIT, and basic-cli's Tcp.listen! cannot bind it again for a while.)
	start_server() {
		"$out/server" "$1" 0 "${3:-}" >"$out/$2.log" 2>&1 &
		servers+=("$!")
		port=""
		for _ in $(seq 50); do
			port="$(sed -n 's/^listening on //p' "$out/$2.log")"
			[[ -n $port ]] && break
			sleep 0.1
		done
		[[ -n $port ]] || { cat "$out/$2.log"; exit 1; }
	}
	# The Roc server, one connection at a time: the client example's two
	# connections, then the server stops by itself.
	start_server one stop 2
	reply="$("$out/client" echo "$port")"
	echo "$reply"
	grep -q 'assembled: Text("fragmented reply")' <<<"$reply"
	grep -q 'closed: { by: Us, clean: True, code: 1000' <<<"$reply"
	grep -q 'server closed: { by: Peer, clean: True, code: 4000' <<<"$reply"
	wait "${servers[-1]}"
	cat "$out/stop.log"
	grep -q 'done: 7 messages, 2 connections' "$out/stop.log"
	# The same on the server side, against a client that pings every second:
	# the first receive_within! gives TimedOut after about 3 s, the second
	# delivers the message the client sends 1.5 s later.
	start_server deadline deadline
	"$PYTHON" -I tests/ping_client.py "$port"
	wait "${servers[-1]}"
	cat "$out/deadline.log"
	grep -q '^first: TimedOut after ' "$out/deadline.log"
	in_range "$(sed -n 's/^first: TimedOut after \([0-9]*\) ms$/\1/p' "$out/deadline.log")" 2500 5000
	grep -q '^second: Message(Text("late")) after ' "$out/deadline.log"
	in_range "$(sed -n 's/^second: .* after \([0-9]*\) ms$/\1/p' "$out/deadline.log")" 1000 2900
	grep -q 'closed: { by: Us, clean: True, code: 1000' "$out/deadline.log"
	# Each mode against the test client.
	for mode in one many; do
		start_server "$mode" "$mode" 1000
		"$out/client" echo "$port" | grep -q 'server closed: { by: Peer, clean: True, code: 4000'
		"$PYTHON" -I tests/server_test.py "$port" "$mode"
		kill "${servers[-1]}"
	done
	# Messages sent with the client's Close: both are answered, and the
	# connection reaches on_close! (the server stops after it).
	for mode in one many; do
		start_server "$mode" "close-$mode" 1
		"$PYTHON" -I tests/server_test.py "$port" close
		wait "${servers[-1]}"
		grep -q 'closed: { by: Peer, clean: True, code: 1000' "$out/close-$mode.log"
		grep -q 'done: 2 messages, 1 connections' "$out/close-$mode.log"
	done
	start_server raw raw
	"$PYTHON" -I tests/server_test.py "$port" raw
	wait "${servers[-1]}"
	cat "$out/raw.log"
	grep -q 'subprotocol: "second"' "$out/raw.log"
fi
