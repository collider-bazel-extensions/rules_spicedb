#!/usr/bin/env bash
# Test: platform access control — org/team/repo permission inheritance.
#
# Schema: organization → team → repository with hierarchical permissions.
# Verifies direct grants, org-admin inheritance, team delegation, and denials.
set -euo pipefail

require_env() {
    [[ -n "${!1:-}" ]] || { echo "ERROR: \$$1 not set" >&2; exit 1; }
}

require_env SPICEDB_GRPC_ADDR
require_env SPICEDB_PRESHARED_KEY
require_env ZED_BIN

PASS=0
FAIL=0

# check_permission OBJECT PERMISSION SUBJECT [expected: true|false]
check_permission() {
    local object="$1" perm="$2" subject="$3" expected="${4:-true}"
    local result
    result=$("$ZED_BIN" permission check "$object" "$perm" "$subject" \
        --endpoint="$SPICEDB_GRPC_ADDR" \
        --token="$SPICEDB_PRESHARED_KEY" \
        --insecure 2>&1)
    if echo "$result" | grep -qi "$expected"; then
        echo "PASS  [$perm] $subject on $object → $expected"
        PASS=$(( PASS + 1 ))
    else
        echo "FAIL  [$perm] $subject on $object → expected $expected, got: $result" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

echo "=== Direct grants ==="

# bob is direct maintainer of api → can maintain, write, and read
check_permission repository:api maintain user:bob true
check_permission repository:api write    user:bob true
check_permission repository:api read     user:bob true

# eve is direct reader of api → can read but not write or maintain
check_permission repository:api read     user:eve true
check_permission repository:api write    user:eve false
check_permission repository:api maintain user:eve false

echo ""
echo "=== Org admin inheritance ==="

# alice is org admin → implicitly has maintain on ALL org repos
check_permission repository:api     maintain user:alice true
check_permission repository:api     write    user:alice true
check_permission repository:api     read     user:alice true
check_permission repository:private maintain user:alice true
check_permission repository:private read     user:alice true

# bob is not org admin → no access to repository:private (no direct grants there)
check_permission repository:private maintain user:bob false
check_permission repository:private read     user:bob false

echo ""
echo "=== Team delegation ==="

# charlie and dave are members of team:backend, which is reader_team on api
# → they get read but not write
check_permission repository:api read     user:charlie true
check_permission repository:api write    user:charlie false
check_permission repository:api read     user:dave    true
check_permission repository:api write    user:dave    false

# charlie and dave have no access to repository:private (team not listed there)
check_permission repository:private read user:charlie false
check_permission repository:private read user:dave    false

echo ""
echo "=== Org admin leads all teams ==="

# alice (org admin) implicitly has team:backend membership
check_permission team:backend membership user:alice   true
# charlie is a direct team member
check_permission team:backend membership user:charlie true
# bob is NOT a team member (only an org member, not admin)
check_permission team:backend membership user:bob     false

echo ""
echo "=== Summary ==="
echo "Passed: $PASS  Failed: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
echo "ALL PASS"
