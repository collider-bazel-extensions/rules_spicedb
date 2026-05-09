#!/usr/bin/env bash
# E2E install smoke. Strategy:
#
#   1. Apply tests/install_smoke/cluster.yaml (Namespace + Secret +
#      SpiceDBCluster with memory backend).
#   2. Wait for the SpiceDBCluster CR to reach a Ready condition AND
#      for the operator-created Deployment to become Available.
#   3. Launch a `zed` pod with the SpiceDBCluster's preshared key.
#      Write a schema, create a relationship, run a permission
#      check, assert ALLOWED.
#
# Proves the value-add of `spicedb_install` end-to-end: operator
# reconciles SpiceDBCluster → Deployment → Pod → live SpiceDB API,
# and the resulting service answers permission queries.
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

# Locate fixtures in runfiles.
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

echo "smoke: applying $CLUSTER_YAML"
"${KCTL[@]}" apply --server-side -f "$CLUSTER_YAML" >/dev/null

# Wait for SpiceDBCluster to reach a Ready condition. The operator
# sets `.status.conditions[].type = "ConfigurationWarnings"` for
# warnings; the canonical Ready signal is the cluster having a
# secretHash AND the operator-created Deployment becoming Available.
# Simpler to wait on the Deployment directly — when it's Available,
# the spicedb pod is serving.
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

# Service for the cluster.
svc_name=$("${KCTL[@]}" -n "$NS" get svc -l "authzed.com/cluster=$CLUSTER" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
[[ -n "$svc_name" ]] || { echo "smoke: FAIL — no service for SpiceDBCluster" >&2; exit 1; }
echo "smoke: SpiceDB Service is $svc_name (gRPC :50051)"

# Run zed via kubectl exec into a transient pod. Schema write + relationship
# + permission check, all against the operator-managed SpiceDB.
echo "smoke: launching zed pod"
"${KCTL[@]}" -n "$NS" run zed-smoke --restart=Never --image=authzed/zed:latest \
    --command -- sleep 600
trap '"${KCTL[@]}" -n "$NS" delete pod zed-smoke --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT
"${KCTL[@]}" -n "$NS" wait pod/zed-smoke --for=condition=Ready --timeout=120s

ZED_ENDPOINT="$svc_name.$NS.svc.cluster.local:50051"

# zed context for this server.
echo "smoke: configuring zed context (--insecure for plaintext gRPC, no TLS in smoke)"
"${KCTL[@]}" -n "$NS" exec zed-smoke -- \
    zed context set smoke "$ZED_ENDPOINT" "$PSK" --insecure

# Pipe the schema file via stdin to `zed schema write`. Needs a
# slightly awkward heredoc-via-stdin because kubectl exec needs -i
# to keep stdin open.
echo "smoke: writing schema"
"${KCTL[@]}" -n "$NS" exec -i zed-smoke -- \
    zed schema write /dev/stdin --insecure < "$SCHEMA_FILE"

echo "smoke: creating relationship document:doc1#viewer@user:alice"
"${KCTL[@]}" -n "$NS" exec zed-smoke -- \
    zed relationship create document:doc1 viewer user:alice --insecure

# Permission check — must return "true" for ALLOWED.
echo "smoke: checking permission document:doc1#view@user:alice"
result=$("${KCTL[@]}" -n "$NS" exec zed-smoke -- \
    zed permission check document:doc1 view user:alice --insecure 2>&1 || true)
if ! grep -qi "true\|HAS_PERMISSION" <<<"$result"; then
  echo "smoke: FAIL — expected permission ALLOWED, got:" >&2
  echo "$result" >&2
  exit 1
fi
echo "smoke: zed permission check returned: $(head -1 <<<"$result")"

# Negative check — bob has no relationship to doc1, should be denied.
echo "smoke: checking permission document:doc1#view@user:bob (negative)"
result_neg=$("${KCTL[@]}" -n "$NS" exec zed-smoke -- \
    zed permission check document:doc1 view user:bob --insecure 2>&1 || true)
if ! grep -qi "false\|NO_PERMISSION" <<<"$result_neg"; then
  echo "smoke: FAIL — expected permission DENIED for bob, got:" >&2
  echo "$result_neg" >&2
  exit 1
fi

echo "smoke: OK — operator install + SpiceDBCluster reconciliation + schema write + permission check (positive + negative) all live"
