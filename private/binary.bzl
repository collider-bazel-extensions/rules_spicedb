"spicedb_binary rule and SpiceDBBinaryInfo provider."

# ---------------------------------------------------------------------------
# Provider
# ---------------------------------------------------------------------------

SpiceDBBinaryInfo = provider(
    doc = "Carries paths to the SpiceDB server and zed CLI binaries.",
    fields = {
        "spicedb":   "File: spicedb server binary",
        "zed":       "File: zed CLI binary",
        "version":   "string: SpiceDB minor version, e.g. '1.30'",
        "all_files": "depset: all binary files required at runtime",
    },
)

# ---------------------------------------------------------------------------
# spicedb_binary_files — injected into each downloaded/system repo
# ---------------------------------------------------------------------------

def _spicedb_binary_files_impl(ctx):
    bins = {f.basename: f for f in ctx.files.bins}

    def _require(name):
        if name not in bins:
            fail(
                "Expected binary '{}' not found in SpiceDB binary repo. ".format(name) +
                "Contents: {}".format(list(bins.keys())),
            )
        return bins[name]

    spicedb_bin = _require("spicedb")
    zed_bin     = _require("zed")

    all_files = depset([spicedb_bin, zed_bin])

    return [
        DefaultInfo(files = all_files),
        SpiceDBBinaryInfo(
            spicedb   = spicedb_bin,
            zed       = zed_bin,
            version   = ctx.attr.version,
            all_files = all_files,
        ),
    ]

spicedb_binary_files = rule(
    implementation = _spicedb_binary_files_impl,
    doc = "Internal: wraps extracted spicedb + zed binaries into SpiceDBBinaryInfo.",
    attrs = {
        "version": attr.string(mandatory = True, doc = "SpiceDB minor version string"),
        "bins": attr.label_list(
            allow_files = True,
            doc = "spicedb and zed binary files from the downloaded/symlinked repo",
        ),
    },
)

# ---------------------------------------------------------------------------
# spicedb_binary — user-facing platform selector
# ---------------------------------------------------------------------------

def _spicedb_binary_impl(ctx):
    bin_info = ctx.attr.binary[SpiceDBBinaryInfo]
    return [
        DefaultInfo(files = bin_info.all_files),
        bin_info,
    ]

spicedb_binary = rule(
    implementation = _spicedb_binary_impl,
    doc = """\
Selects the correct SpiceDB binary for the current platform.

Typically consumed indirectly via spicedb_schema and spicedb_test.
""",
    attrs = {
        "binary": attr.label(
            mandatory = True,
            providers = [SpiceDBBinaryInfo],
            doc = "Platform-specific binary target (set via select() in BUILD.bazel)",
        ),
        "version": attr.string(
            default = "1.30",
            doc = "SpiceDB minor version. Must match the binary repo version.",
        ),
    },
)
