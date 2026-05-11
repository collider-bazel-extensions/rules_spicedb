"""Bzlmod module extension: fetch or symlink spicedb + zed binaries.

Two modes (can coexist per-version):
  - spicedb.version(versions = [...]) — hermetic; download tarballs from
    authzed GitHub releases at the pinned sha256s.
  - spicedb.system(versions = [...])  — reuse the host's spicedb + zed
    installs (e.g. `brew install authzed/tap/spicedb`).

Maintainer flow for adding/bumping a minor version: run
`tools/update_checksums.sh <spicedb-ver> <zed-ver>` which pulls the
relevant checksums.txt from each release and rewrites the
`_SPICEDB_VERSIONS` block here.
"""

# SpiceDB + zed version pairs, keyed by SpiceDB minor version.
# SpiceDB releases: https://github.com/authzed/spicedb/releases
# zed releases:     https://github.com/authzed/zed/releases
# SHA-256s come from each release's `checksums.txt` (zed linux uses
# the `_gnu` tarball — the musl variant is a separate asset.)
_SPICEDB_VERSIONS = {
    "1.52": {
        "spicedb_version": "1.52.0",
        "zed_version":     "1.1.1",
        "linux_amd64": {
            "spicedb_url":    "https://github.com/authzed/spicedb/releases/download/v1.52.0/spicedb_1.52.0_linux_amd64.tar.gz",
            "spicedb_sha256": "7897dc9dc3f5dc2308e7e1d710294afc69fe719e4e92ef51b9d2446ee84fe0dc",
            "zed_url":        "https://github.com/authzed/zed/releases/download/v1.1.1/zed_1.1.1_linux_amd64_gnu.tar.gz",
            "zed_sha256":     "2a0901904302a9f59bf35f96dd904897b7664f79a8cc2eede594422468ceb34b",
        },
        "darwin_arm64": {
            "spicedb_url":    "https://github.com/authzed/spicedb/releases/download/v1.52.0/spicedb_1.52.0_darwin_arm64.tar.gz",
            "spicedb_sha256": "b6b62ca1b68b9472eef987397a362806a9d25a43b5a23290ba250bb7deb4577c",
            "zed_url":        "https://github.com/authzed/zed/releases/download/v1.1.1/zed_1.1.1_darwin_arm64.tar.gz",
            "zed_sha256":     "67247f0054ea07c12dd1853393f4611ca2f1791319a43ad28e303d0e2bedcedf",
        },
        "darwin_amd64": {
            "spicedb_url":    "https://github.com/authzed/spicedb/releases/download/v1.52.0/spicedb_1.52.0_darwin_amd64.tar.gz",
            "spicedb_sha256": "24cb41313d65d428e3061e2f0ed0a94d6b8b30643a0c471edb3cadbee9075515",
            "zed_url":        "https://github.com/authzed/zed/releases/download/v1.1.1/zed_1.1.1_darwin_amd64.tar.gz",
            "zed_sha256":     "43454c28de34a68018b105076b71f4f43d8142b76c907d7e019594fbecaa129f",
        },
    },
}

PLATFORMS = ["linux_amd64", "darwin_arm64", "darwin_amd64"]

_BINARY_REPO_BUILD = """\
filegroup(
    name = "spicedb_bin",
    srcs = ["spicedb"],
    visibility = ["//visibility:public"],
)
filegroup(
    name = "zed_bin",
    srcs = ["zed"],
    visibility = ["//visibility:public"],
)
filegroup(
    name = "all_files",
    srcs = [":spicedb_bin", ":zed_bin"],
    visibility = ["//visibility:public"],
)
"""

_STUB_BUILD = """\
# Stub repo for a non-host platform.  Never selected at build time.
filegroup(name = "spicedb_bin", srcs = [], visibility = ["//visibility:public"])
filegroup(name = "zed_bin",     srcs = [], visibility = ["//visibility:public"])
filegroup(name = "all_files",   srcs = [], visibility = ["//visibility:public"])
"""

# ---------------------------------------------------------------------------
# Downloaded binaries (spicedb.version())
# ---------------------------------------------------------------------------

def _spicedb_binary_repo_impl(rctx):
    version  = rctx.attr.version
    platform = rctx.attr.platform

    if version not in _SPICEDB_VERSIONS:
        fail("Unsupported SpiceDB version: {}. Supported: {}".format(
            version, ", ".join(_SPICEDB_VERSIONS.keys())))

    info = _SPICEDB_VERSIONS[version].get(platform)
    if not info:
        fail("No binaries for SpiceDB {} on {}".format(version, platform))

    for key in ["spicedb_sha256", "zed_sha256"]:
        if not info[key]:
            fail(
                ("rules_spicedb: SHA-256 for {} (SpiceDB {} / {}) is unset. " +
                 "Run tools/update_checksums.sh to pin real values.").format(
                    key, version, platform),
            )

    rctx.download_and_extract(
        url    = info["spicedb_url"],
        sha256 = info["spicedb_sha256"],
        output = "spicedb_bin/",
    )
    rctx.download_and_extract(
        url    = info["zed_url"],
        sha256 = info["zed_sha256"],
        output = "zed_bin/",
    )
    # Symlink binaries to repo root for the BUILD filegroups.
    rctx.symlink("spicedb_bin/spicedb", "spicedb")
    rctx.symlink("zed_bin/zed",         "zed")
    rctx.file("BUILD.bazel", _BINARY_REPO_BUILD)

spicedb_binary_repo = repository_rule(
    implementation = _spicedb_binary_repo_impl,
    attrs = {
        "version":  attr.string(mandatory = True),
        "platform": attr.string(mandatory = True),
    },
)

# ---------------------------------------------------------------------------
# System binaries (spicedb.system())
# ---------------------------------------------------------------------------

_PLATFORM_OS_MAP = {
    "linux_amd64":  "linux",
    "darwin_arm64": "mac os x",
    "darwin_amd64": "mac os x",
}

_SPICEDB_SEARCH_PATHS = [
    "/usr/local/bin",
    "/usr/bin",
]

_ZED_SEARCH_PATHS = [
    "/usr/local/bin",
    "/usr/bin",
]

def _check_container_runtime(rctx):
    """No-op for SpiceDB: no container runtime required."""
    pass

def _spicedb_system_binary_repo_impl(rctx):
    version  = rctx.attr.version
    bin_dir  = rctx.attr.bin_dir
    platform = rctx.attr.platform

    # If this repo's platform doesn't match the host OS, emit a stub.
    expected_os = _PLATFORM_OS_MAP.get(platform, "")
    if expected_os and rctx.os.name.lower() != expected_os:
        rctx.file("BUILD.bazel", _STUB_BUILD)
        return

    home = rctx.os.environ.get("HOME", "")

    # Auto-detect spicedb.
    spicedb_path = ""
    if bin_dir:
        spicedb_path = bin_dir + "/spicedb"
    else:
        result = rctx.execute(["sh", "-c", "command -v spicedb 2>/dev/null || true"])
        if result.return_code == 0 and result.stdout.strip():
            spicedb_path = result.stdout.strip()

    if not spicedb_path:
        search = _SPICEDB_SEARCH_PATHS + ([home + "/.local/bin"] if home else [])
        for path in search:
            if rctx.execute(["test", "-f", path + "/spicedb"]).return_code == 0:
                spicedb_path = path + "/spicedb"
                break

    if not spicedb_path:
        fail(
            "spicedb not found in PATH or common locations.\n" +
            "Install with: brew install authzed/tap/spicedb  (macOS)\n" +
            "              See https://github.com/authzed/spicedb/releases\n" +
            "Or pass bin_dir explicitly: spicedb.system(versions=[...], bin_dir='/path/to/bin')",
        )

    # Auto-detect zed.
    zed_path = ""
    if bin_dir:
        if rctx.execute(["test", "-f", bin_dir + "/zed"]).return_code == 0:
            zed_path = bin_dir + "/zed"

    if not zed_path:
        result = rctx.execute(["sh", "-c", "command -v zed 2>/dev/null || true"])
        if result.return_code == 0 and result.stdout.strip():
            zed_path = result.stdout.strip()

    if not zed_path:
        search = _ZED_SEARCH_PATHS + ([home + "/.local/bin"] if home else [])
        for path in search:
            if rctx.execute(["test", "-f", path + "/zed"]).return_code == 0:
                zed_path = path + "/zed"
                break

    if not zed_path:
        fail(
            "zed CLI not found in PATH or common locations.\n" +
            "Install with: brew install authzed/tap/zed  (macOS)\n" +
            "              See https://github.com/authzed/zed/releases\n" +
            "Or pass bin_dir explicitly: spicedb.system(versions=[...], bin_dir='/path/to/bin')",
        )

    rctx.symlink(spicedb_path, "spicedb")
    rctx.symlink(zed_path,     "zed")
    rctx.file("BUILD.bazel", _BINARY_REPO_BUILD)

spicedb_system_binary_repo = repository_rule(
    implementation = _spicedb_system_binary_repo_impl,
    attrs = {
        "version":  attr.string(mandatory = True),
        "bin_dir":  attr.string(default = ""),
        "platform": attr.string(default = ""),
    },
)

# ---------------------------------------------------------------------------
# Module extension
# ---------------------------------------------------------------------------

_version_tag = tag_class(
    doc = "Download pre-built spicedb + zed binaries from GitHub.",
    attrs = {
        "versions": attr.string_list(
            doc       = "SpiceDB minor versions (e.g. ['1.30']).",
            mandatory = True,
        ),
    },
)

_system_tag = tag_class(
    doc = "Use host-installed spicedb + zed binaries.",
    attrs = {
        "versions": attr.string_list(
            doc       = "SpiceDB minor versions to register (e.g. ['1.30']).",
            mandatory = True,
        ),
        "bin_dir": attr.string(
            doc     = "Directory containing spicedb and zed. " +
                      "Omit to auto-detect from PATH and common locations.",
            default = "",
        ),
    },
)

def _spicedb_extension(module_ctx):
    for mod in module_ctx.modules:
        for tag in mod.tags.version:
            for version in tag.versions:
                for platform in PLATFORMS:
                    repo_name = "spicedb_{}_{}".format(
                        version.replace(".", "_"), platform)
                    spicedb_binary_repo(
                        name     = repo_name,
                        version  = version,
                        platform = platform,
                    )

        for tag in mod.tags.system:
            for version in tag.versions:
                for platform in PLATFORMS:
                    repo_name = "spicedb_{}_{}".format(
                        version.replace(".", "_"), platform)
                    spicedb_system_binary_repo(
                        name     = repo_name,
                        version  = version,
                        bin_dir  = tag.bin_dir,
                        platform = platform,
                    )

spicedb = module_extension(
    implementation = _spicedb_extension,
    tag_classes    = {
        "version": _version_tag,
        "system":  _system_tag,
    },
)
