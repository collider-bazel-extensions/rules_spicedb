"spicedb_relationships rule and SpiceDBRelationshipsInfo provider."

load("//private:schema.bzl", "SpiceDBSchemaInfo")

# ---------------------------------------------------------------------------
# Provider
# ---------------------------------------------------------------------------

SpiceDBRelationshipsInfo = provider(
    doc = "Carries relationship tuple files to be loaded after schema is written.",
    fields = {
        "relationship_files": "depset: text files, one relationship tuple per line",
        "schema":             "SpiceDBSchemaInfo: the schema that must be written first",
    },
)

# ---------------------------------------------------------------------------
# Rule
# ---------------------------------------------------------------------------

def _spicedb_relationships_impl(ctx):
    schema_info = ctx.attr.schema[SpiceDBSchemaInfo]

    rel_files = depset(
        ctx.files.srcs,
        order = "preorder",
    )

    return [
        DefaultInfo(files = depset(transitive = [schema_info.schema_files, rel_files])),
        SpiceDBRelationshipsInfo(
            relationship_files = rel_files,
            schema             = schema_info,
        ),
    ]

spicedb_relationships = rule(
    implementation = _spicedb_relationships_impl,
    doc = """\
Declares relationship tuples to load into SpiceDB after the schema is written.

Each source file is a plain-text file with one relationship tuple per line:

    document:doc1#owner@user:alice
    document:doc1#viewer@user:bob

Lines starting with `#` and blank lines are ignored.

    spicedb_relationships(
        name = "seed",
        schema = ":schema",
        srcs = ["relationships.txt"],
    )
""",
    attrs = {
        "srcs": attr.label_list(
            allow_files = [".txt", ".yaml", ".zed"],
            mandatory = True,
            doc = "Relationship tuple files. One tuple per line: object:id#relation@subject:id",
        ),
        "schema": attr.label(
            mandatory = True,
            providers = [SpiceDBSchemaInfo],
            doc = "The spicedb_schema target whose schema is written before loading relationships.",
        ),
    },
)
