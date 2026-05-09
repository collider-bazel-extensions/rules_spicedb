"spicedb_test macro: wraps any *_test rule with an ephemeral SpiceDB instance."

load("@rules_shell//shell:sh_test.bzl", "sh_test")
load("//private:schema.bzl", "SpiceDBSchemaInfo")
load("//private:relationships.bzl", "SpiceDBRelationshipsInfo")

# ---------------------------------------------------------------------------
# Internal rule
# ---------------------------------------------------------------------------

def _spicedb_launcher_test_impl(ctx):
    schema_info = ctx.attr.schema[SpiceDBSchemaInfo]
    binary_info = schema_info.binary

    schema_files = schema_info.schema_files
    rel_files    = depset()
    if ctx.attr.relationships:
        rel_info  = ctx.attr.relationships[SpiceDBRelationshipsInfo]
        rel_files = rel_info.relationship_files

    manifest_content = struct(
        workspace          = ctx.workspace_name,
        spicedb_bin        = binary_info.spicedb.short_path,
        zed_bin            = binary_info.zed.short_path,
        schema_files       = [f.short_path for f in schema_files.to_list()],
        relationship_files = [f.short_path for f in rel_files.to_list()],
        preshared_key      = ctx.attr.preshared_key,
    )
    manifest = ctx.actions.declare_file(ctx.label.name + "_spicedb_manifest.json")
    ctx.actions.write(
        output  = manifest,
        content = json.encode(manifest_content),
    )

    launcher_src = ctx.file.launcher
    workspace    = ctx.workspace_name
    test_bin     = ctx.attr.test_binary.files_to_run.executable.short_path

    wrapper = ctx.actions.declare_file(ctx.label.name + "_spicedb_wrapper.sh")
    ctx.actions.write(
        output = wrapper,
        content = """\
#!/usr/bin/env bash
set -euo pipefail
RUNFILES_ROOT="${{TEST_SRCDIR:-${{RUNFILES_DIR:-}}}}"
if [[ -z "$RUNFILES_ROOT" ]]; then
  echo "[rules_spicedb] Neither TEST_SRCDIR nor RUNFILES_DIR is set" >&2
  exit 1
fi
export RULES_SPICEDB_MANIFEST="$RUNFILES_ROOT/{workspace}/{manifest}"
export RULES_SPICEDB_TEST_BINARY="$RUNFILES_ROOT/{workspace}/{test_bin}"
export RULES_SPICEDB_MODE=test
exec "$RUNFILES_ROOT/{workspace}/{launcher}" "$@"
""".format(
            workspace = workspace,
            manifest  = manifest.short_path,
            launcher  = launcher_src.short_path,
            test_bin  = test_bin,
        ),
        is_executable = True,
    )

    runfiles = ctx.runfiles(
        files            = [manifest, launcher_src, wrapper],
        transitive_files = depset(
            transitive = [binary_info.all_files, schema_files, rel_files],
        ),
    ).merge(ctx.attr.test_binary.default_runfiles)

    return [DefaultInfo(executable = wrapper, runfiles = runfiles)]

_spicedb_launcher_test = rule(
    implementation = _spicedb_launcher_test_impl,
    test = True,
    doc  = "Internal rule. Use the spicedb_test macro instead.",
    attrs = {
        "schema": attr.label(
            mandatory = True,
            providers = [SpiceDBSchemaInfo],
        ),
        "relationships": attr.label(
            mandatory = False,
            providers = [SpiceDBRelationshipsInfo],
        ),
        "test_binary": attr.label(
            mandatory  = True,
            executable = True,
            cfg        = "target",
        ),
        "launcher": attr.label(
            default           = Label("//private:launcher.py"),
            allow_single_file = True,
            executable        = False,
        ),
        "preshared_key": attr.string(default = "rules_spicedb_test_key"),
    },
)

# ---------------------------------------------------------------------------
# spicedb_test macro
# ---------------------------------------------------------------------------

def spicedb_test(
        name,
        schema,
        srcs = None,
        deps = None,
        relationships = None,
        preshared_key = "rules_spicedb_test_key",
        size = "medium",
        timeout = None,
        tags = None,
        test_rule = None,
        **kwargs):
    """Macro: runs a test with an ephemeral SpiceDB instance.

    Wraps any *_test rule (default: sh_test; pass test_rule= for others) with
    a launcher that:
      1. Starts spicedb serve-testing on a random free port.
      2. Writes the schema (from spicedb_schema.srcs) via zed schema write.
      3. Optionally loads relationships (from spicedb_relationships.srcs).
      4. Exports SPICEDB_GRPC_ADDR, SPICEDB_PRESHARED_KEY, ZED_BIN,
         ZED_ENDPOINT, ZED_TOKEN, ZED_INSECURE to the test binary.
      5. exec's the wrapped test binary.
      6. SpiceDB is terminated when the test process group exits.

    Args:
        name:          Target name.
        schema:        Label of a spicedb_schema target (required).
        srcs:          Test source files (forwarded to test_rule).
        deps:          Test dependencies (forwarded to test_rule).
        relationships: Optional label of a spicedb_relationships target.
        preshared_key: SpiceDB preshared key for the test instance.
                       Default "rules_spicedb_test_key".
        size:          Bazel test size. Default "medium".
        timeout:       Bazel test timeout override.
        tags:          Extra tags.
        test_rule:     The *_test rule for the inner binary. Default: sh_test.
        **kwargs:      Remaining kwargs forwarded to test_rule.
    """
    srcs  = srcs  or []
    deps  = deps  or []
    tags  = tags  or []
    # Bazel 8+ removed `native.sh_test`, so the default has to load
    # from rules_shell. Consumers can override `test_rule = ...` to
    # point at another *_test rule (py_test, go_test, etc.) if they
    # don't want rules_shell as a transitive dep.
    _test_rule = test_rule or sh_test

    inner_name = name + "_inner"
    _test_rule(
        name = inner_name,
        srcs = srcs,
        deps = deps,
        tags = tags + ["manual"],
        **kwargs
    )

    _spicedb_launcher_test(
        name          = name,
        schema        = schema,
        relationships = relationships,
        test_binary   = ":" + inner_name,
        preshared_key = preshared_key,
        size          = size,
        timeout       = timeout,
        tags          = tags,
    )
