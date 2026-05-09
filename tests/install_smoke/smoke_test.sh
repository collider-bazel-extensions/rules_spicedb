#!/usr/bin/env bash
# E2E install smoke. Strategy:
#
#   1. Apply tests/install_smoke/cluster.yaml (Namespace + Secret +
#      SpiceDBCluster with memory backend).
#   2. Wait for the operator-created Deployment to be Available.
#   3. `kubectl port-forward` the in-cluster SpiceDB Service to
#      localhost:50051. (We use host-side `zed` rather than a
#      kubectl-exec'd zed pod because authzed/zed:latest is a
#      from-scratch image without /bin/sh — `kubectl run --command
#      -- sleep 600` finds nothing to run.)
#   4. Configure zed against localhost:50051 with the preshared key.
#   5. Write schema, create document:doc1#viewer@user:alice.
#   6. Assert positive permission check (alice → ALLOWED).
#   7. Assert negative permission check (bob → DENIED).
#
# Proves end-to-end: operator install + SpiceDBCluster reconciliation
# + live SpiceDB API answering permission queries.
set -euo pipefail

CLUSTER_NAME="cluster"
env_file="$TEST_TMPDIR/${CLUSTER_NAME}.env"
[[ -f "$env_file" ]] || { echo "missing kind env file" >&2; exit 1; }
# shellcheck disable=SC1090
source "$env_file"

KCTL=("$KUBECTL" --kubeconfig="$KUBECONFIG")

NS="spicedb-smoke"
CLUSTER="smoke"
PSK="smoke-fixture-preshared-key-do-not-use-in-prod"

_resolve() {
  local rel="$1"
  for cand in \
    "${RUNFILES_DIR:-}/_main/$rel" \
    "$(dirname "$0").runfiles/_main/$rel" \
    "$rel"; do
    [[ -f "$cand" ]] && { echo "$cand"; return 0; }
  done
  return 1
}

CLUSTER_YAML="$(_resolve tests/install_smoke/cluster.yaml)" \
    || { echo "smoke: cluster.yaml not in runfiles" >&2; exit 1; }
SCHEMA_FILE="$(_resolve tests/install_smoke/schema.zed)" \
    || { echo "smoke: schema.zed not in runfiles" >&2; exit 1; }

command -v zed >/dev/null 2>&1 || {
  echo "smoke: \`zed\` not on PATH. Install from https://github.com/authzed/zed/releases" >&2
  exit 1
}

echo "smoke: applying $CLUSTER_YAML"
"${KCTL[@]}" apply --server-side -f "$CLUSTER_YAML" >/dev/null

echo "smoke: waiting for operator-created Deployment to be Available"
deadline=$(( $(date +%s) + 240 ))
deploy_name=""
while (( $(date +%s) < deadline )); do
  deploy_name=$("${KCTL[@]}" -n "$NS" get deploy -l "authzed.com/cluster=$CLUSTER" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  [[ -n "$deploy_name" ]] && break
  sleep 3
done
if [[ -z "$deploy_name" ]]; then
  echo "smoke: FAIL — operator never created a Deployment for SpiceDBCluster/$CLUSTER" >&2
  "${KCTL[@]}" -n "$NS" get spicedbcluster "$CLUSTER" -o yaml >&2 || true
  "${KCTL[@]}" -n spicedb-operator logs deploy/spicedb-operator --tail=80 >&2 || true
  exit 1
fi
echo "smoke: operator-created Deployment is $deploy_name"
"${KCTL[@]}" -n "$NS" wait "deploy/$deploy_name" --for=condition=Available --timeout=240s

svc_name=$("${KCTL[@]}" -n "$NS" get svc -l "authzed.com/cluster=$CLUSTER" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
[[ -n "$svc_name" ]] || { echo "smoke: FAIL — no service for SpiceDBCluster" >&2; exit 1; }
echo "smoke: SpiceDB Service is $svc_name (gRPC :50051)"

# Port-forward in background; track PID for cleanup.
echo "smoke: port-forwarding $svc_name -> localhost:50051"
"${KCTL[@]}" -n "$NS" port-forward "svc/$svc_name" 50051:50051 >/tmp/pf.log 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" >/dev/null 2>&1 || true' EXIT

# Wait for port-forward to be listening.
deadline=$(( $(date +%s) + 30 ))
while (( $(date +%s) < deadline )); do
  if (echo > /dev/tcp/localhost/50051) >/dev/null 2>&1; then break; fi
  sleep 1
done
if ! (echo > /dev/tcp/localhost/50051) >/dev/null 2>&1; then
  echo "smoke: FAIL — port-forward never listened on localhost:50051" >&2
  cat /tmp/pf.log >&2 || true
  exit 1
fi

# zed prompts interactively for a keyring passphrase on first context
# creation. CI has no TTY and zed errors with "inappropriate ioctl for
# device". ZED_KEYRING_PASSWORD bypasses the prompt — zed uses the env
# var as the encryption key for the on-disk credential file.
export ZED_KEYRING_PASSWORD="smoke-fixture-keyring-password"

echo "smoke: configuring zed context"
zed context set smoke localhost:50051 "$PSK" --insecure

echo "smoke: writing schema"
zed schema write "$SCHEMA_FILE" --insecure

echo "smoke: creating relationship document:doc1#viewer@user:alice"
zed relationship create document:doc1 viewer user:alice --insecure

echo "smoke: checking permission document:doc1#view@user:alice"
result=$(zed permission check document:doc1 view user:alice --insecure 2>&1 || true)
if ! grep -qi "true\|HAS_PERMISSION" <<<"$result"; then
  echo "smoke: FAIL — expected permission ALLOWED, got:" >&2
  echo "$result" >&2
  exit 1
fi
echo "smoke: zed permission check returned: $(head -1 <<<"$result")"

echo "smoke: checking permission document:doc1#view@user:bob (negative)"
result_neg=$(zed permission check document:doc1 view user:bob --insecure 2>&1 || true)
if ! grep -qi "false\|NO_PERMISSION" <<<"$result_neg"; then
  echo "smoke: FAIL — expected permission DENIED for bob, got:" >&2
  echo "$result_neg" >&2
  exit 1
fi

echo "smoke: OK — operator install + SpiceDBCluster reconciliation + schema write + permission check (positive + negative) all live"
