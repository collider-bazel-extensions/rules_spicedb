#!/usr/bin/env bash
# Test (#7): spicedb_test forwards the target's args, env and --test_env to
# the test binary, alongside the SpiceDB variables.
set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ $# -eq 3 ]] || fail "want 3 args, got $#: $*"
[[ "$1" == "--flag" ]] || fail "arg 1 = '$1', want '--flag'"
[[ "$2" == "two words" ]] || fail "arg 2 = '$2', want 'two words'"
[[ "$3" == "tests/schema/example.zed" ]] || fail "arg 3 = '$3', want tests/schema/example.zed"
[[ -f "$3" ]] || fail "\$(rootpath) arg $3 is not a file in runfiles"
echo "PASS: args"

[[ "${RULES_SPICEDB_TEST_PLAIN:-}" == "plain value" ]] || fail "env RULES_SPICEDB_TEST_PLAIN='${RULES_SPICEDB_TEST_PLAIN:-}'"
[[ "${RULES_SPICEDB_TEST_SCHEMA:-}" == "tests/schema/example.zed" ]] || fail "env RULES_SPICEDB_TEST_SCHEMA='${RULES_SPICEDB_TEST_SCHEMA:-}'"
echo "PASS: env"

# Set in .bazelrc via --test_env.
[[ "${RULES_SPICEDB_TEST_ENV:-}" == "from_test_env" ]] || fail "--test_env RULES_SPICEDB_TEST_ENV='${RULES_SPICEDB_TEST_ENV:-}'"
echo "PASS: --test_env"

for v in SPICEDB_GRPC_ADDR SPICEDB_PRESHARED_KEY ZED_BIN ZED_ENDPOINT ZED_TOKEN; do
    [[ -n "${!v:-}" ]] || fail "\$$v not set"
done
"$ZED_BIN" schema read --endpoint="$SPICEDB_GRPC_ADDR" --token="$SPICEDB_PRESHARED_KEY" \
    --insecure | grep -q "definition document" || fail "schema not readable"
echo "PASS: SpiceDB variables"
