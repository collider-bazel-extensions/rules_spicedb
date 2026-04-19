# Legacy WORKSPACE shim for rules_spicedb.
# Bzlmod users: use MODULE.bazel + extensions.bzl instead.
# WORKSPACE users: use repositories.bzl.

workspace(name = "rules_spicedb")

load("//:repositories.bzl", "spicedb_system_dependencies")

spicedb_system_dependencies(versions = ["1.30"])
