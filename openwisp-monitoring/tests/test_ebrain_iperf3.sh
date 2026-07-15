#!/bin/sh

set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
WRAPPER="$SCRIPT_DIR/../files/ebrain-iperf3"
TMP_DIR="$(mktemp -d)"
MOCK_BIN="$TMP_DIR/bin"
MARKER="$TMP_DIR/command-exec-timeout-seconds"

cleanup() {
	rm -rf "$TMP_DIR"
}
trap cleanup EXIT HUP INT TERM

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

assert_contains() {
	value="$1"
	expected="$2"
	case "$value" in
		*"$expected"*) ;;
		*) fail "expected '$expected' in '$value'" ;;
	esac
}

decode_result() {
	value="$1"
	prefix='EBRAIN_IPERF3_GZIP_BASE64_V1:'
	case "$value" in
		"$prefix"*) encoded="${value#"$prefix"}" ;;
		*) fail "result does not use the compressed transport envelope" ;;
	esac
	encoded_file="$TMP_DIR/result.b64"
	gzip_file="$TMP_DIR/result.json.gz"
	printf '%s' "$encoded" >"$encoded_file"
	if ! base64 -d <"$encoded_file" >"$gzip_file" 2>/dev/null; then
		base64 -D <"$encoded_file" >"$gzip_file" 2>/dev/null \
			|| fail "unable to decode result envelope"
	fi
	gzip -dc "$gzip_file"
}

mkdir -p "$MOCK_BIN"
cat >"$MOCK_BIN/iperf3" <<'EOF'
#!/bin/sh

if [ "${1:-}" = "--version" ]; then
	echo "iperf 3.test"
	exit 0
fi
if [ "${MOCK_IPERF3_MODE:-success}" = "hang" ]; then
	trap '' TERM
	while :; do :; done
fi
if [ "${MOCK_IPERF3_MODE:-success}" = "large" ]; then
	printf '{"intervals":['
	i=0
	while [ "$i" -lt 5000 ]; do
		printf '{"sum":{"seconds":1,"bits_per_second":123456789}},'
		i=$((i + 1))
	done
	echo '{"sentinel":"large-result"}],"end":{}}'
	exit 0
fi
echo '{"end":{}}'
EOF
chmod +x "$MOCK_BIN/iperf3"

printf '180\n' >"$MARKER"
output="$(PATH="$MOCK_BIN:$PATH" EBRAIN_IPERF3_COMMAND_TIMEOUT_MARKER="$MARKER" sh "$WRAPPER" preflight)"
assert_contains "$output" '"ok":true'
assert_contains "$output" '"command_timeout_seconds":180'
assert_contains "$output" '"max_test_duration_seconds":120'
assert_contains "$output" '"version":"3"'
assert_contains "$output" '"result_transport":"gzip_base64_v1"'

printf '30\n' >"$MARKER"
if output="$(PATH="$MOCK_BIN:$PATH" EBRAIN_IPERF3_COMMAND_TIMEOUT_MARKER="$MARKER" sh "$WRAPPER" preflight 2>&1)"; then
	fail "legacy command timeout unexpectedly passed preflight"
fi
assert_contains "$output" '"error":"command_timeout_unsupported"'

printf '180\n' >"$MARKER"
if output="$(PATH="$MOCK_BIN:$PATH" EBRAIN_IPERF3_COMMAND_TIMEOUT_MARKER="$MARKER" sh "$WRAPPER" client-run --target 192.0.2.1 --duration 121 2>&1)"; then
	fail "duration above 120 seconds unexpectedly passed"
fi
assert_contains "$output" '"error":"duration_out_of_range"'

output="$(PATH="$MOCK_BIN:$PATH" EBRAIN_IPERF3_COMMAND_TIMEOUT_MARKER="$MARKER" sh "$WRAPPER" client-run --target 192.0.2.1 --duration 120 --omit 30 --connect-timeout 3000)"
decoded="$(decode_result "$output")"
assert_contains "$decoded" '"end"'

output="$(PATH="$MOCK_BIN:$PATH" MOCK_IPERF3_MODE=large EBRAIN_IPERF3_COMMAND_TIMEOUT_MARKER="$MARKER" sh "$WRAPPER" client-run --target 192.0.2.1 --duration 120 --connect-timeout 3000)"
[ "${#output}" -lt 40000 ] || fail "compressed result exceeded the transport limit"
decoded="$(decode_result "$output")"
assert_contains "$decoded" '"sentinel":"large-result"'

SERVER_STATE_DIR="$TMP_DIR/server-state"
mkdir -p "$SERVER_STATE_DIR"
printf 'server-log-sentinel\n' >"$SERVER_STATE_DIR/job-1.server.log"
output="$(PATH="$MOCK_BIN:$PATH" EBRAIN_IPERF3_STATE_DIR="$SERVER_STATE_DIR" sh "$WRAPPER" server-status --job-id job-1)"
assert_contains "$output" '"log_encoding":"gzip_base64_v1"'
encoded="$(printf '%s' "$output" | sed -n 's/.*"log":"\([^"]*\)".*/\1/p')"
decoded="$(decode_result "EBRAIN_IPERF3_GZIP_BASE64_V1:$encoded")"
assert_contains "$decoded" 'server-log-sentinel'

if output="$(PATH="$MOCK_BIN:$PATH" EBRAIN_IPERF3_COMMAND_TIMEOUT_MARKER="$MARKER" sh "$WRAPPER" client-run --target 192.0.2.1 --duration 120 --omit 30 --connect-timeout 60000 2>&1)"; then
	fail "over-budget request unexpectedly passed"
fi
assert_contains "$output" '"error":"time_budget_exceeded"'

printf '4\n' >"$MARKER"
if output="$(PATH="$MOCK_BIN:$PATH" MOCK_IPERF3_MODE=hang EBRAIN_IPERF3_COMMAND_TIMEOUT_MARKER="$MARKER" EBRAIN_IPERF3_MIN_COMMAND_TIMEOUT=4 EBRAIN_IPERF3_COMMAND_GUARD_SECONDS=1 EBRAIN_IPERF3_COMMAND_OVERHEAD_SECONDS=0 sh "$WRAPPER" client-run --target 192.0.2.1 --duration 1 --connect-timeout 500 2>&1)"; then
	fail "watchdog timeout unexpectedly succeeded"
else
	status=$?
fi
[ "$status" -eq 124 ] || fail "expected watchdog exit 124, got $status"
assert_contains "$output" '"error":"client_deadline_exceeded"'

echo "PASS: ebrain-iperf3 timeout policy"
