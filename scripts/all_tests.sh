#!/usr/bin/env bash
# The local checks. Usage: ROC=/path/to/roc scripts/all_tests.sh [--e2e]
# With --e2e, also builds examples/client.roc, starts tests/echo_server.py on
# port 9001 and runs the client against it (needs python3). When SurrealDB
# answers on 127.0.0.1:8000 (root/root, any auth), also runs `client surreal`.
# Then builds examples/server.roc and runs, against each of its modes, the
# client example and tests/server_test.py (ports 9002-9005). $PYTHON (default
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
	out="$(mktemp -d)"
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

	# The Roc server, one connection at a time: the client example's two
	# connections, then the server stops by itself.
	"$out/server" one 9002 2 >"$out/one.log" 2>&1 &
	servers+=("$!")
	sleep 0.5
	reply="$("$out/client" echo 9002)"
	echo "$reply"
	grep -q 'assembled: Text("fragmented reply")' <<<"$reply"
	grep -q 'closed: { by: Us, clean: True, code: 1000' <<<"$reply"
	grep -q 'server closed: { by: Peer, clean: True, code: 4000' <<<"$reply"
	wait "${servers[-1]}"
	cat "$out/one.log"
	grep -q 'done: 7 messages, 2 connections' "$out/one.log"
	# Each mode against the test client.
	for mode in one many; do
		port=$([[ $mode == one ]] && echo 9003 || echo 9004)
		"$out/server" "$mode" "$port" 1000 >"$out/$mode.log" 2>&1 &
		servers+=("$!")
		sleep 0.5
		"$out/client" echo "$port" | grep -q 'server closed: { by: Peer, clean: True, code: 4000'
		"$PYTHON" -I tests/server_test.py "$port" "$mode"
		kill "${servers[-1]}"
	done
	"$out/server" raw 9005 >"$out/raw.log" 2>&1 &
	servers+=("$!")
	sleep 0.5
	"$PYTHON" -I tests/server_test.py 9005 raw
	wait "${servers[-1]}"
	cat "$out/raw.log"
	grep -q 'subprotocol: "second"' "$out/raw.log"
fi
