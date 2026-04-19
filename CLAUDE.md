# rules_spicedb

Bazel rules for running SpiceDB in tests. Provides hermetic, parallel-safe
SpiceDB instances for `*_test` targets with zero external infrastructure —
uses `spicedb serve-testing` (in-memory, no backend required).

## Commit requirements

- All tests must pass before any commit with code changes (`bazel test //tests/...`).
- All documentation (`README.md`, `DESIGN.md`, `CLAUDE.md`) must be updated to
  reflect any code changes before committing. This includes new rules, changed
  attributes, new public API surface, and behaviour changes.

## Repo layout

```
rules_spicedb/
├── MODULE.bazel              # Bzlmod module definition
├── WORKSPACE                 # Legacy workspace (compatibility shim)
├── defs.bzl                  # Public API re-exports
├── extensions.bzl            # Module extension: spicedb + zed binary repos
├── repositories.bzl          # Legacy WORKSPACE equivalents of extensions.bzl
├── BUILD.bazel               # Platform config_settings + spicedb_binary targets
├── DESIGN.md                 # Architecture and design decisions
├── private/
│   ├── binary.bzl            # spicedb_binary rule + SpiceDBBinaryInfo provider
│   ├── schema.bzl            # spicedb_schema rule + SpiceDBSchemaInfo provider
│   ├── relationships.bzl     # spicedb_relationships rule + SpiceDBRelationshipsInfo provider
│   ├── test.bzl              # spicedb_test macro + _spicedb_launcher_test rule
│   ├── server.bzl            # spicedb_server rule + spicedb_health_check rule
│   └── launcher.py           # Launcher: start SpiceDB → import schema/rels → exec test | serve
├── toolchain/
│   └── toolchain.bzl         # Toolchain type declaration
└── tests/
    ├── BUILD.bazel
    ├── schema/               # Example .zed schema files
    │   └── example.zed
    └── seed/                 # Example relationship files
        └── relationships.txt
```

## Key concepts

### Providers (chain)

```
SpiceDBBinaryInfo
  └─ SpiceDBSchemaInfo   (carries a SpiceDBBinaryInfo)
       └─ SpiceDBRelationshipsInfo  (carries a SpiceDBSchemaInfo)
            └─ consumed by spicedb_test and spicedb_server
```

### `spicedb_test` isolation model

Every `spicedb_test` target gets:
- Its own `spicedb serve-testing` instance (in-memory, no disk state)
- A randomly assigned free TCP port for the gRPC endpoint
- SpiceDB is terminated when the test process group exits (Bazel handles this)

No shared state between tests → full `--jobs` parallelism is safe.

### `spicedb serve-testing`

`spicedb serve-testing` is SpiceDB's built-in testing mode:
- Completely in-memory (no backing datastore needed)
- Each instance is independent and isolated per test
- Supports the full SpiceDB gRPC API
- Starts in ~1 second

### Schema and relationships loading

After the server is ready, the launcher uses `zed import` to load schema and
relationships in a single call. The launcher generates a YAML file from the
`.zed` schema files and relationship tuple files, then calls:

```
zed import <generated_yaml> --endpoint=localhost:PORT --token=KEY --insecure
```

The generated YAML format:
```yaml
schema: |-
  definition user {}
  definition document { ... }
relationships: |-
  document:doc1#owner@user:alice
  document:doc1#viewer@user:bob
```

### Relationship file format

Relationship files are plain text with one tuple per line:
```
document:doc1#owner@user:alice
document:doc1#viewer@user:bob
```

Lines starting with `#` and blank lines are ignored.

### Port allocation

The launcher uses `socket.bind(('127.0.0.1', 0))` to find a free port.
SpiceDB doesn't support passing an open socket fd, so the socket is closed
before `spicedb serve-testing` binds. Up to 5 retries handle the rare TOCTOU
race. Retries only trigger on "address already in use" errors; all other
failures fail immediately with the full server log.

### Binary acquisition

`extensions.bzl` (Bzlmod) and `repositories.bzl` (WORKSPACE) both support two
modes:

| Tag / function                    | Behavior                                         |
|-----------------------------------|--------------------------------------------------|
| `spicedb.version()`               | Downloads spicedb + zed tarballs from GitHub     |
| `spicedb.system()`                | Symlinks host-installed spicedb + zed            |
| `spicedb_system_dependencies()`   | WORKSPACE equivalent of `spicedb.system()`       |

**Auto-detection** — when `bin_dir` is omitted, the repository rule:
1. Runs `command -v spicedb` (PATH lookup).
2. Probes common locations: `/usr/local/bin`, `/usr/bin`, `$HOME/.local/bin`.

Same for `zed`.

### `spicedb_server` readiness protocol

`spicedb_server` writes `$TEST_TMPDIR/<name>.env` atomically once fully ready:

```
SPICEDB_GRPC_ADDR=localhost:PORT
SPICEDB_PRESHARED_KEY=rules_spicedb_test_key
ZED_ENDPOINT=localhost:PORT
ZED_TOKEN=rules_spicedb_test_key
ZED_INSECURE=true
ZED_BIN=/path/to/zed
```

`spicedb_health_check` exits 0 iff this file exists.

## Public API

```python
load("@rules_spicedb//:defs.bzl",
    "spicedb_schema",
    "spicedb_relationships",
    "spicedb_test",
    "spicedb_server",
    "spicedb_health_check",
)

spicedb_schema(
    name = "my_schema",
    srcs = ["schema.zed"],
)

spicedb_relationships(
    name   = "my_seed",
    schema = ":my_schema",
    srcs   = ["relationships.txt"],
)

# Single-binary test (schema + relationships applied, test binary exec'd):
spicedb_test(
    name          = "my_test",
    srcs          = ["my_test.sh"],
    schema        = ":my_schema",
    relationships = ":my_seed",      # optional
    preshared_key = "testkey",       # optional, default "rules_spicedb_test_key"
    test_rule     = sh_test,         # optional; default sh_test
)

# Long-running service for rules_itest:
spicedb_server(
    name          = "authz",
    schema        = ":my_schema",
    relationships = ":my_seed",      # optional
    preshared_key = "testkey",       # optional
)

spicedb_health_check(
    name   = "authz_health",
    server = ":authz",
)
```

### Environment variables

| Variable              | Example                   | Description                        |
|-----------------------|---------------------------|------------------------------------|
| `SPICEDB_GRPC_ADDR`   | `localhost:54321`         | gRPC endpoint                      |
| `SPICEDB_PRESHARED_KEY` | `rules_spicedb_test_key` | Auth token                        |
| `ZED_ENDPOINT`        | `localhost:54321`         | Alias for zed CLI                  |
| `ZED_TOKEN`           | `rules_spicedb_test_key`  | Alias for zed CLI                  |
| `ZED_INSECURE`        | `true`                    | Disables TLS for zed CLI           |
| `ZED_BIN`             | `/path/to/zed`            | Absolute path to zed binary        |

### MODULE.bazel (Bzlmod)

```python
bazel_dep(name = "rules_spicedb", version = "0.1.0")

spicedb = use_extension("@rules_spicedb//:extensions.bzl", "spicedb")
spicedb.system(versions = ["1.30"])
use_repo(spicedb,
    "spicedb_1_30_linux_amd64",
    "spicedb_1_30_darwin_arm64",
    "spicedb_1_30_darwin_amd64",
)
```

### WORKSPACE (legacy)

```python
load("@rules_spicedb//:repositories.bzl", "spicedb_system_dependencies")
spicedb_system_dependencies(versions = ["1.30"])
```

## Development

### Running the self-tests

```sh
bazel test //tests/...
```

Tests require `spicedb` and `zed` to be installed on the host. Both are
auto-detected from PATH. To install:

```sh
# macOS
brew install authzed/tap/spicedb authzed/tap/zed

# Linux (Fedora/RHEL)
sudo dnf install spicedb zed

# or download from GitHub releases:
# https://github.com/authzed/spicedb/releases
# https://github.com/authzed/zed/releases
```

All tests must pass before any commit with code changes.

### Test results (last full run: TBD)

| Test target                         | What it verifies                                              |
|-------------------------------------|---------------------------------------------------------------|
| `//tests:schema_smoke_test`         | Schema written; `zed schema read` returns expected definitions |
| `//tests:seed_smoke_test`           | Relationships loaded; `zed permission check` resolves correctly |
| `//tests:spicedb_health_check_test` | Health check exits non-zero without env file, 0 when present  |
| `//tests:spicedb_server_test`       | spicedb_server starts, writes env file, SIGTERM shuts down    |

### Launcher script

`private/launcher.py` is the heart of both `spicedb_test` and `spicedb_server`.
The mode is selected by `RULES_SPICEDB_MODE` (set by the generated wrapper):

| Mode     | Behaviour                                                        |
|----------|------------------------------------------------------------------|
| `test`   | `_spicedb_setup()` → `os.execve(test_binary)`                    |
| `server` | `_spicedb_setup()` → write env file → `signal.pause()`           |

Both modes share `_spicedb_setup`, which:
1. Reads the JSON manifest (`RULES_SPICEDB_MANIFEST`).
2. Resolves all runfile paths.
3. Ensures spicedb and zed binaries have the execute bit set.
4. Finds a free TCP port and starts `spicedb serve-testing`.
5. Polls via `zed schema read` until the server is ready (max 30 s).
6. Generates a `zed import` YAML from schema and relationship files.
7. Calls `zed import` to write schema and relationships atomically.
8. Retries on port conflicts (max 5 attempts); fails immediately on other errors.
9. Returns a `_SpiceDBState` dataclass with connection details.

### Test script requirements

All test shell scripts must:
- Begin with `set -euo pipefail`.
- Use `require_env VAR` guards for every `SPICEDB_*` and `ZED_*` variable.
- Use `"$ZED_BIN"` (not bare `zed`) to reference the zed binary.
- Pass `--endpoint`, `--token`, and `--insecure` to all zed commands
  (or rely on `ZED_ENDPOINT`/`ZED_TOKEN`/`ZED_INSECURE` env vars).

### Style

- All `.bzl` files use 4-space indentation.
- Provider fields are documented with inline comments.
- Public rules/macros have docstrings.
- `private/` contains implementation details; only `defs.bzl` is the stable API.

## Known limitations

- **spicedb + zed must be installed.** Unlike rules_pg which auto-detects any
  host-installed PostgreSQL, `spicedb.version()` download SHA-256 checksums are
  placeholders — pin real values before using download mode.
- **Windows not supported** (no pre-built binary source; PRs welcome).
- **Port allocation is TOCTOU.** SpiceDB doesn't support passing an open socket
  fd; the launcher retries on conflicts (max 5 attempts) but a persistent race
  could theoretically cause a test failure.
- **Startup time ~1 s.** `spicedb serve-testing` starts quickly, making per-test
  isolation viable for most test suites.
- **No caveated relationships in seed files.** The relationship tuple format
  `object:id#relation@subject:id` does not support caveats. Caveated
  relationships must be created programmatically in the test binary.
