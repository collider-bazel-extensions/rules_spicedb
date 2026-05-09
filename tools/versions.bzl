"""Maintainer-side: spicedb-operator bundle.yaml pin.

The operator publishes a single `bundle.yaml` per release at
`github.com/authzed/spicedb-operator/releases/download/<v>/bundle.yaml`.
4kLOC YAML; controller image, CRD, RBAC, Namespace, ConfigMap with
the operator's per-SpiceDB-version update graph.
"""

SPICEDB_OPERATOR_VERSIONS = {
    "v1.25.0": {
        "url": "https://github.com/authzed/spicedb-operator/releases/download/v1.25.0/bundle.yaml",
        "sha256": "faa874927cf9163f1322ddb400b70c6bc6fb40ae6eb93180d3c82bbbe8c1a563",
    },
}
