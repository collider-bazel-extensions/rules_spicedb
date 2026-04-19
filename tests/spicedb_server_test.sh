#!/usr/bin/env bash
# Test: spicedb_server starts, writes correct env file, shuts down on SIGTERM.
set -euo pipefail

require_env() {
    [[ -n "${!1:-}" ]] || { echo "ERROR: \$$1 not set" >&2; exit 1; }
}

require_env TEST_TMPDIR

RUNFILES="${TEST_SRCDIR:-${RUNFILES_DIR:-${BASH_SOURCE[0]}.runfiles}}"

# Locate the server launcher script (generated for test_server)
server_launcher=""
for candidate in \
    "${RUNFILES}/_main/tests/test_server_spicedb_server.sh" \
    "${RUNFILES}/rules_spicedb/tests/test_server_spicedb_server.sh"
do
    if [[ -f "$candidate" ]]; then
        server_launcher="$candidate"
        break
    fi
done

if [[ -z "$server_launcher" ]]; then
    echo "ERROR: server launcher not found under RUNFILES=$RUNFILES" >&2
    find "${RUNFILES}" -name "*spicedb_server*" 2>/dev/null | head -10 >&2
    exit 1
fi

env_file="${TEST_TMPDIR}/test_server.env"
rm -f "$env_file"

# Start server in background.
"$server_launcher" &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null; wait "$server_pid" 2>/dev/null || true' EXIT

# Wait for env file (up to 60 s).
echo "waiting for spicedb_server to be ready..."
deadline=$(( $(date +%s) + 60 ))
while [[ ! -f "$env_file" ]]; do
    [[ $(date +%s) -le $deadline ]] || {
        echo "FAIL: server startup timed out" >&2
        exit 1
    }
    kill -0 "$server_pid" 2>/dev/null || {
        echo "FAIL: server process exited unexpectedly" >&2
        exit 1
    }
    sleep 1
done
echo "PASS: env file written"

# Verify required variables are present.
source "$env_file"

for var in SPICEDB_GRPC_ADDR SPICEDB_PRESHARED_KEY ZED_ENDPOINT ZED_TOKEN ZED_INSECURE ZED_BIN; do
    [[ -n "${!var:-}" ]] || {
        echo "FAIL: $var is not set in env file" >&2
        exit 1
    }
    echo "  $var=${!var}"
done
echo "PASS: all required env vars present"

# Verify ZED_ENDPOINT matches SPICEDB_GRPC_ADDR.
[[ "$ZED_ENDPOINT" == "$SPICEDB_GRPC_ADDR" ]] || {
    echo "FAIL: ZED_ENDPOINT ($ZED_ENDPOINT) != SPICEDB_GRPC_ADDR ($SPICEDB_GRPC_ADDR)" >&2
    exit 1
}
echo "PASS: ZED_ENDPOINT matches SPICEDB_GRPC_ADDR"

# Send SIGTERM and wait for clean shutdown.
echo "sending SIGTERM..."
kill "$server_pid"
wait "$server_pid" || true
echo "PASS: server shut down cleanly"

trap '' EXIT
echo "PASS"
