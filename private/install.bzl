"""Cluster-deploy primitives — `spicedb_install` + `spicedb_install_health_check`.

Pure glue over `rules_kubectl`'s `kubectl_apply` + a vendored
spicedb-operator bundle.yaml (one Deployment + the
`spicedbclusters.authzed.com` CRD + RBAC). Sibling to the
existing test-time primitives (`spicedb_server`,
`spicedb_health_check`) — those stay unchanged in v0.2; the new
install primitives use `_install_` in their names to avoid the
collision.

Wait shape:
  - Deployment `spicedb-operator/spicedb-operator` Available
  - CRD `spicedbclusters.authzed.com` registered
"""

load("@rules_kubectl//:defs.bzl", "kubectl_apply", "kubectl_apply_health_check")

_OPERATOR_DEPLOY = "spicedb-operator"
_OPERATOR_CRD = "spicedbclusters.authzed.com"

def spicedb_install(
        name,
        namespace = "spicedb-operator",
        wait_timeout = "300s",
        **kwargs):
    """Apply the pinned spicedb-operator bundle into `namespace` and
    block until the operator Deployment is Available AND the
    `spicedbclusters.authzed.com` CRD is registered before idling.

    Drops into `itest_service.exe`. Wait timeout 300s — the
    operator image is small (~50 MB); cold pulls clear comfortably
    well under 5 minutes.

    The operator's bundle.yaml hardcodes `spicedb-operator` as the
    namespace in cluster-scoped RoleBindings; changing the
    `namespace` arg here would only affect the wait-side
    Deployment lookup. To install into a different namespace, fork
    the bundle.
    """
    extra_deploys = kwargs.pop("wait_for_deployments", [])
    extra_rollouts = kwargs.pop("wait_for_rollouts", [])
    extra_crds = kwargs.pop("wait_for_crds", [])
    kubectl_apply(
        name = name,
        manifests = ["@rules_spicedb//private/manifests:spicedb_operator.yaml"],
        namespace = namespace,
        # Bundle includes a Namespace resource, so create_namespace
        # is unnecessary here. Setting it would no-op via apply
        # idempotence; explicit False keeps the surface honest.
        create_namespace = False,
        server_side = True,
        wait_for_deployments = [_OPERATOR_DEPLOY] + list(extra_deploys),
        wait_for_rollouts = list(extra_rollouts),
        wait_for_crds = [_OPERATOR_CRD] + list(extra_crds),
        wait_timeout = wait_timeout,
        **kwargs
    )

def spicedb_install_health_check(
        name,
        namespace = "spicedb-operator",
        **kwargs):
    """Readiness probe paired with `spicedb_install`. Same wait
    shape with `--timeout=0s`.

    Named `_install_health_check` (not just `_health_check`) to
    avoid colliding with the v0.1 `spicedb_health_check` macro,
    which pairs with `spicedb_server` (the test-time SpiceDB
    launcher). Both health checks coexist; pick the one matching
    your install vs test composition.
    """
    extra_deploys = kwargs.pop("wait_for_deployments", [])
    extra_rollouts = kwargs.pop("wait_for_rollouts", [])
    extra_crds = kwargs.pop("wait_for_crds", [])
    kubectl_apply_health_check(
        name = name,
        namespace = namespace,
        wait_for_deployments = [_OPERATOR_DEPLOY] + list(extra_deploys),
        wait_for_rollouts = list(extra_rollouts),
        wait_for_crds = [_OPERATOR_CRD] + list(extra_crds),
        **kwargs
    )
