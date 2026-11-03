#!/usr/bin/env bash
# The local checks. Usage: ROC=/path/to/roc scripts/all_tests.sh [--e2e]
# With --e2e, also builds examples/client.roc, starts tests/echo_server.py on
# port 9001 and runs the client against it (needs python3). When SurrealDB
# answers on 127.0.0.1:8000 (root/root, any auth), also runs `client surreal`.
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
	# Each mode against the test client.
	for mode in one many; do
		start_server "$mode" "$mode" 1000
		"$out/client" echo "$port" | grep -q 'server closed: { by: Peer, clean: True, code: 4000'
		"$PYTHON" -I tests/server_test.py "$port" "$mode"
		kill "${servers[-1]}"
	done
	start_server raw raw
	"$PYTHON" -I tests/server_test.py "$port" raw
	wait "${servers[-1]}"
	cat "$out/raw.log"
	grep -q 'subprotocol: "second"' "$out/raw.log"
fi
