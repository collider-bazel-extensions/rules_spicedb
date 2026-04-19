"spicedb_schema rule and SpiceDBSchemaInfo provider."

load("//private:binary.bzl", "SpiceDBBinaryInfo")

# ---------------------------------------------------------------------------
# Provider
# ---------------------------------------------------------------------------

SpiceDBSchemaInfo = provider(
    doc = "Carries an ordered set of SpiceDB schema (.zed) files and the binary to use.",
    fields = {
        "schema_files": "depset: .zed files in application order (preorder)",
        "binary":       "SpiceDBBinaryInfo: the server and CLI binaries",
    },
)

# ---------------------------------------------------------------------------
# Rule
# ---------------------------------------------------------------------------

def _spicedb_schema_impl(ctx):
    binary_info = ctx.attr.binary[SpiceDBBinaryInfo]

    schema_files = depset(
        ctx.files.srcs,
        order = "preorder",
    )

    return [
        DefaultInfo(files = schema_files),
        SpiceDBSchemaInfo(
            schema_files = schema_files,
            binary       = binary_info,
        ),
    ]

spicedb_schema = rule(
    implementation = _spicedb_schema_impl,
    doc = """\
Declares an ordered set of SpiceDB schema files (.zed) that define the
permission model.

Files are written to SpiceDB in the order they appear in `srcs`.
Concatenated content must be a valid SpiceDB Schema Language definition.

    spicedb_schema(
        name = "schema",
        srcs = ["schema.zed"],
    )
""",
    attrs = {
        "srcs": attr.label_list(
            allow_files = [".zed"],
            mandatory = True,
            doc = "SpiceDB schema files in application order.",
        ),
        "binary": attr.label(
            default = Label("//:spicedb_default"),
            providers = [SpiceDBBinaryInfo],
            doc = "spicedb_binary target to use.",
        ),
    },
)
