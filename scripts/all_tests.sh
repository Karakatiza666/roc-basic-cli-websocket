#!/usr/bin/env bash
# The local checks. Usage: ROC=/path/to/roc scripts/all_tests.sh [--e2e]
# With --e2e, also builds examples/client.roc, starts tests/echo_server.py on
# port 9001 and runs the client against it (needs python3). When SurrealDB
# answers on 127.0.0.1:8000 (root/root, any auth), also runs `client surreal`.
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
	"$ROC" build examples/client.roc --output="$out/client"
	python3 -I tests/echo_server.py 9001 2>"$out/server.log" &
	server=$!
	trap 'kill $server 2>/dev/null || true' EXIT
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
fi
