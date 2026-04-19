#!/usr/bin/env bash
# Test: spicedb_health_check exits non-zero without env file, 0 when present.
set -euo pipefail

require_env() {
    [[ -n "${!1:-}" ]] || { echo "ERROR: \$$1 not set" >&2; exit 1; }
}

require_env TEST_TMPDIR

RUNFILES="${TEST_SRCDIR:-${RUNFILES_DIR:-${BASH_SOURCE[0]}.runfiles}}"

# Locate the health check script (generated for test_server_health)
health_check=""
for candidate in \
    "${RUNFILES}/_main/tests/test_server_health_health_check.sh" \
    "${RUNFILES}/rules_spicedb/tests/test_server_health_health_check.sh"
do
    if [[ -f "$candidate" ]]; then
        health_check="$candidate"
        break
    fi
done

if [[ -z "$health_check" ]]; then
    echo "ERROR: health check script not found under RUNFILES=$RUNFILES" >&2
    find "${RUNFILES}" -name "*health_check*" 2>/dev/null | head -10 >&2
    exit 1
fi

# 1. Without the env file the health check should fail.
env_file="${TEST_TMPDIR}/test_server.env"
rm -f "$env_file"

if "$health_check" 2>/dev/null; then
    echo "FAIL: health check should exit non-zero without env file" >&2
    exit 1
fi
echo "PASS: health check correctly fails when env file is absent"

# 2. With the env file present it should succeed.
echo "SPICEDB_GRPC_ADDR=localhost:50051" > "$env_file"

if ! "$health_check"; then
    echo "FAIL: health check should exit 0 when env file is present" >&2
    exit 1
fi
echo "PASS: health check correctly passes when env file is present"

rm -f "$env_file"
echo "PASS"
