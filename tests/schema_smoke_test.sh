#!/usr/bin/env bash
# Test: schema is written correctly and readable via zed.
set -euo pipefail

require_env() {
    [[ -n "${!1:-}" ]] || { echo "ERROR: \$$1 not set" >&2; exit 1; }
}

require_env SPICEDB_GRPC_ADDR
require_env SPICEDB_PRESHARED_KEY
require_env ZED_BIN

echo "reading schema..."
schema=$("$ZED_BIN" schema read \
    --endpoint="$SPICEDB_GRPC_ADDR" \
    --token="$SPICEDB_PRESHARED_KEY" \
    --insecure 2>&1)

if [[ -z "$schema" ]]; then
    echo "FAIL: schema is empty" >&2
    exit 1
fi

echo "$schema" | grep -q "definition document" || {
    echo "FAIL: schema missing 'definition document'" >&2
    echo "schema: $schema" >&2
    exit 1
}

echo "$schema" | grep -q "definition user" || {
    echo "FAIL: schema missing 'definition user'" >&2
    exit 1
}

echo "PASS: schema written and verified"
