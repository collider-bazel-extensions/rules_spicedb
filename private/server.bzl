"spicedb_server rule and spicedb_health_check rule."

load("//private:schema.bzl", "SpiceDBSchemaInfo")
load("//private:relationships.bzl", "SpiceDBRelationshipsInfo")

# ---------------------------------------------------------------------------
# spicedb_server
# ---------------------------------------------------------------------------

def _spicedb_server_impl(ctx):
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
    ctx.actions.write(output = manifest, content = json.encode(manifest_content))

    launcher_src  = ctx.file.launcher
    env_file_name = ctx.label.name + ".env"
    workspace     = ctx.workspace_name

    wrapper = ctx.actions.declare_file(ctx.label.name + "_spicedb_server.sh")
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
export RULES_SPICEDB_MODE=server
export RULES_SPICEDB_SERVER_NAME="{server_name}"
exec "$RUNFILES_ROOT/{workspace}/{launcher}" "$@"
""".format(
            workspace   = workspace,
            manifest    = manifest.short_path,
            launcher    = launcher_src.short_path,
            server_name = ctx.label.name,
        ),
        is_executable = True,
    )

    runfiles = ctx.runfiles(
        files            = [manifest, launcher_src, wrapper],
        transitive_files = depset(
            transitive = [binary_info.all_files, schema_files, rel_files],
        ),
    )

    return [DefaultInfo(executable = wrapper, runfiles = runfiles)]

spicedb_server = rule(
    implementation = _spicedb_server_impl,
    executable     = True,
    doc            = """\
Produces a long-running SpiceDB server for multi-service integration tests.

When executed, spicedb_server:
  1. Starts spicedb serve-testing on a random free port.
  2. Writes the schema via zed schema write.
  3. Optionally loads relationships from spicedb_relationships files.
  4. Writes SPICEDB_GRPC_ADDR / SPICEDB_PRESHARED_KEY / ZED_* variables
     to $TEST_TMPDIR/<name>.env atomically once fully ready.
  5. Blocks until SIGTERM or SIGINT, then stops SpiceDB cleanly.

Use with rules_itest:

    spicedb_server(
        name   = "authz",
        schema = ":schema",
        seed   = ":seed",
    )

    spicedb_health_check(
        name   = "authz_health",
        server = ":authz",
    )

    itest_service(
        name         = "authz_svc",
        exe          = ":authz",
        health_check = ":authz_health",
    )
""",
    attrs = {
        "schema": attr.label(
            mandatory = True,
            providers = [SpiceDBSchemaInfo],
            doc = "spicedb_schema target to write before serving.",
        ),
        "relationships": attr.label(
            mandatory = False,
            providers = [SpiceDBRelationshipsInfo],
            doc = "Optional spicedb_relationships target to load after schema.",
        ),
        "launcher": attr.label(
            default           = Label("//private:launcher.py"),
            allow_single_file = True,
            executable        = False,
        ),
        "preshared_key": attr.string(
            default = "rules_spicedb_test_key",
            doc     = "SpiceDB preshared key. Exported as SPICEDB_PRESHARED_KEY.",
        ),
    },
)

# ---------------------------------------------------------------------------
# spicedb_health_check
# ---------------------------------------------------------------------------

def _spicedb_health_check_impl(ctx):
    server_name   = ctx.attr.server.label.name
    env_file_name = server_name + ".env"

    script = ctx.actions.declare_file(ctx.label.name + "_health_check.sh")
    ctx.actions.write(
        output = script,
        content = """\
#!/usr/bin/env bash
set -euo pipefail
env_file="${{TEST_TMPDIR}}/{env_file}"
if [[ -f "$env_file" ]]; then
  exit 0
fi
echo "[rules_spicedb] spicedb_server env file not yet present: $env_file" >&2
exit 1
""".format(env_file = env_file_name),
        is_executable = True,
    )
    return [DefaultInfo(executable = script, runfiles = ctx.runfiles(files = [script]))]

spicedb_health_check = rule(
    implementation = _spicedb_health_check_impl,
    executable     = True,
    doc            = """\
Health-check binary for a spicedb_server target.

Exits 0 when $TEST_TMPDIR/<server-name>.env exists — written by spicedb_server
only after SpiceDB is fully up, schema written, and relationships loaded.

    spicedb_health_check(name = "authz_health", server = ":authz")
""",
    attrs = {
        "server": attr.label(
            mandatory = True,
            doc       = "The spicedb_server target to health-check.",
        ),
    },
)
