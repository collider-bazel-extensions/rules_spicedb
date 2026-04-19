#!/usr/bin/env bash
# Test: relationships are loaded and permissions resolve correctly.
set -euo pipefail

require_env() {
    [[ -n "${!1:-}" ]] || { echo "ERROR: \$$1 not set" >&2; exit 1; }
}

require_env SPICEDB_GRPC_ADDR
require_env SPICEDB_PRESHARED_KEY
require_env ZED_BIN

# alice is owner of doc1 → should have write permission
echo "checking alice write on doc1..."
result=$("$ZED_BIN" permission check document:doc1 write user:alice \
    --endpoint="$SPICEDB_GRPC_ADDR" \
    --token="$SPICEDB_PRESHARED_KEY" \
    --insecure 2>&1)
echo "  result: $result"
echo "$result" | grep -qi "true" || {
    echo "FAIL: alice should have write on doc1 (is owner)" >&2
    exit 1
}
echo "PASS: alice has write on doc1"

# bob is viewer of doc1 → should have read but not write permission
echo "checking bob read on doc1..."
result=$("$ZED_BIN" permission check document:doc1 read user:bob \
    --endpoint="$SPICEDB_GRPC_ADDR" \
    --token="$SPICEDB_PRESHARED_KEY" \
    --insecure 2>&1)
echo "  result: $result"
echo "$result" | grep -qi "true" || {
    echo "FAIL: bob should have read on doc1 (is viewer)" >&2
    exit 1
}
echo "PASS: bob has read on doc1"

echo "checking bob write on doc1 (should be denied)..."
result=$("$ZED_BIN" permission check document:doc1 write user:bob \
    --endpoint="$SPICEDB_GRPC_ADDR" \
    --token="$SPICEDB_PRESHARED_KEY" \
    --insecure 2>&1)
echo "  result: $result"
echo "$result" | grep -qi "false" || {
    echo "FAIL: bob should NOT have write on doc1 (only viewer)" >&2
    exit 1
}
echo "PASS: bob does not have write on doc1"

echo "PASS"
