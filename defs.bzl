"""Public API for rules_spicedb.

Two families of primitives:

  Test-time (v0.1 — boots a transient SpiceDB locally for a test):
    - spicedb_schema, spicedb_relationships
    - spicedb_test
    - spicedb_server, spicedb_health_check

  Install-time (v0.2 — deploys spicedb-operator to a real cluster):
    - spicedb_install, spicedb_install_health_check

Load:

    load("@rules_spicedb//:defs.bzl",
        # test-time
        "spicedb_schema", "spicedb_relationships",
        "spicedb_test", "spicedb_server", "spicedb_health_check",
        # install-time
        "spicedb_install", "spicedb_install_health_check",
    )
"""

load("//private:schema.bzl", _spicedb_schema = "spicedb_schema")
load("//private:relationships.bzl", _spicedb_relationships = "spicedb_relationships")
load("//private:test.bzl", _spicedb_test = "spicedb_test")
load("//private:server.bzl",
    _spicedb_server = "spicedb_server",
    _spicedb_health_check = "spicedb_health_check",
)
load("//private:install.bzl",
    _spicedb_install = "spicedb_install",
    _spicedb_install_health_check = "spicedb_install_health_check",
)

spicedb_schema               = _spicedb_schema
spicedb_relationships        = _spicedb_relationships
spicedb_test                 = _spicedb_test
spicedb_server               = _spicedb_server
spicedb_health_check         = _spicedb_health_check
spicedb_install              = _spicedb_install
spicedb_install_health_check = _spicedb_install_health_check
