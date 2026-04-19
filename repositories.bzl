"""Legacy WORKSPACE equivalents of extensions.bzl.

For Bzlmod users, use extensions.bzl instead.
"""

load(":extensions.bzl",
    "PLATFORMS",
    "spicedb_system_binary_repo",
    "spicedb_binary_repo",
)

def spicedb_system_dependencies(versions, bin_dir = ""):
    """Declare spicedb + zed binary repos using host-installed binaries.

    Equivalent to spicedb.system() in MODULE.bazel.

    Args:
        versions: list of SpiceDB minor version strings (e.g. ["1.30"]).
        bin_dir:  directory containing spicedb and zed binaries.
                  Omit to auto-detect from PATH and common locations.
    """
    for version in versions:
        for platform in PLATFORMS:
            repo_name = "spicedb_{}_{}".format(version.replace(".", "_"), platform)
            spicedb_system_binary_repo(
                name     = repo_name,
                version  = version,
                bin_dir  = bin_dir,
                platform = platform,
            )

def spicedb_dependencies(versions):
    """Declare spicedb + zed binary repos by downloading from GitHub.

    Equivalent to spicedb.version() in MODULE.bazel.

    Args:
        versions: list of SpiceDB minor version strings (e.g. ["1.30"]).
    """
    for version in versions:
        for platform in PLATFORMS:
            repo_name = "spicedb_{}_{}".format(version.replace(".", "_"), platform)
            spicedb_binary_repo(
                name     = repo_name,
                version  = version,
                platform = platform,
            )
