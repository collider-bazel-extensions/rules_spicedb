"""Public API for rules_spicedb.

Load this file in your BUILD files:

    load("@rules_spicedb//:defs.bzl",
        "spicedb_schema",
        "spicedb_relationships",
        "spicedb_test",
        "spicedb_server",
        "spicedb_health_check",
    )
"""

load("//private:schema.bzl", _spicedb_schema = "spicedb_schema")
load("//private:relationships.bzl", _spicedb_relationships = "spicedb_relationships")
load("//private:test.bzl", _spicedb_test = "spicedb_test")
load("//private:server.bzl",
    _spicedb_server = "spicedb_server",
    _spicedb_health_check = "spicedb_health_check",
)

spicedb_schema        = _spicedb_schema
spicedb_relationships = _spicedb_relationships
spicedb_test          = _spicedb_test
spicedb_server        = _spicedb_server
spicedb_health_check  = _spicedb_health_check
