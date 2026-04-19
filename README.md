# rules_spicedb

Bazel rules for running [SpiceDB](https://authzed.com/spicedb) in tests.
Provides hermetic, parallel-safe SpiceDB instances for `*_test` targets with
zero external infrastructure — uses `spicedb serve-testing` (in-memory, no
backend required). Designed for use with
[rules_itest](https://github.com/dzbarsky/rules_itest).

## Features

- **`spicedb_test`** — wrap any `*_test` rule with an ephemeral SpiceDB
  instance; schema and relationships loaded before the test binary runs
- **`spicedb_server`** + **`spicedb_health_check`** — long-running server for
  `rules_itest` multi-service tests
- **Parallel-safe** — every test target gets its own server on a unique port
- **`~1 s` startup** — `spicedb serve-testing` is in-memory with no disk setup
- **System or downloaded binaries** — symlink host-installed `spicedb`/`zed`
  or download tarballs from GitHub

## Quick start

### 1. Declare the dependency

**MODULE.bazel (Bzlmod)**:
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

**WORKSPACE (legacy)**:
```python
load("@rules_spicedb//:repositories.bzl", "spicedb_system_dependencies")
spicedb_system_dependencies(versions = ["1.30"])
```

### 2. Define schema and relationships

**schema.zed** — SpiceDB Schema Language:
```
definition user {}

definition document {
    relation owner:  user
    relation viewer: user

    permission write = owner
    permission read  = viewer + owner
}
```

**relationships.txt** — one tuple per line:
```
document:doc1#owner@user:alice
document:doc1#viewer@user:bob
```

### 3. Write a test

**BUILD.bazel**:
```python
load("@rules_spicedb//:defs.bzl",
    "spicedb_schema", "spicedb_relationships", "spicedb_test")

spicedb_schema(
    name = "schema",
    srcs = ["schema.zed"],
)

spicedb_relationships(
    name   = "seed",
    schema = ":schema",
    srcs   = ["relationships.txt"],
)

spicedb_test(
    name          = "authz_test",
    srcs          = ["authz_test.sh"],
    schema        = ":schema",
    relationships = ":seed",
)
```

**authz_test.sh**:
```bash
#!/usr/bin/env bash
set -euo pipefail

# SpiceDB connection details are injected as env vars.
# ZED_ENDPOINT, ZED_TOKEN, ZED_INSECURE are set for the zed CLI.
result=$("$ZED_BIN" permission check document:doc1 write user:alice \
    --endpoint="$SPICEDB_GRPC_ADDR" \
    --token="$SPICEDB_PRESHARED_KEY" \
    --insecure)

echo "$result" | grep -q "true" || { echo "FAIL: alice should have write"; exit 1; }
echo "PASS"
```

## Rules reference

### `spicedb_schema`

Declares SpiceDB schema files (`.zed`) that define the permission model.
Files are concatenated and written to SpiceDB in listed order.

```python
spicedb_schema(
    name   = "schema",
    srcs   = ["schema.zed"],           # .zed files in application order
    binary = "//:spicedb_default",     # optional; default platform binary
)
```

### `spicedb_relationships`

Declares relationship tuple files to load after schema is written.

```python
spicedb_relationships(
    name   = "seed",
    schema = ":schema",                # required
    srcs   = ["relationships.txt"],    # one tuple per line: obj:id#rel@subj:id
)
```

### `spicedb_test`

Macro that wraps any `*_test` rule with an ephemeral SpiceDB instance.

```python
spicedb_test(
    name          = "my_test",
    srcs          = ["my_test.sh"],
    schema        = ":schema",         # required
    relationships = ":seed",           # optional
    preshared_key = "testkey",         # optional, default "rules_spicedb_test_key"
    test_rule     = sh_test,           # optional; default sh_test
    size          = "medium",          # optional
    # ... other test_rule kwargs
)
```

### `spicedb_server` + `spicedb_health_check`

Long-running server for multi-service integration tests via rules_itest.

```python
spicedb_server(
    name          = "authz",
    schema        = ":schema",
    relationships = ":seed",           # optional
    preshared_key = "testkey",         # optional
)

spicedb_health_check(
    name   = "authz_health",
    server = ":authz",
)
```

### Environment variables

The following variables are set in test binaries and written to the `.env` file
for `spicedb_server`:

| Variable                | Example                    | Description                    |
|-------------------------|----------------------------|--------------------------------|
| `SPICEDB_GRPC_ADDR`     | `localhost:54321`          | gRPC endpoint                  |
| `SPICEDB_PRESHARED_KEY` | `rules_spicedb_test_key`   | Auth token                     |
| `ZED_ENDPOINT`          | `localhost:54321`          | Convenience alias for zed CLI  |
| `ZED_TOKEN`             | `rules_spicedb_test_key`   | Convenience alias for zed CLI  |
| `ZED_INSECURE`          | `true`                     | Disables TLS for zed CLI       |
| `ZED_BIN`               | `/path/to/zed`             | Absolute path to zed binary    |

## Integration with rules_itest

```python
load("@rules_spicedb//:defs.bzl",
    "spicedb_schema", "spicedb_relationships", "spicedb_server",
    "spicedb_health_check")
load("@rules_itest//:defs.bzl", "itest_service", "service_test")

spicedb_schema(name = "schema", srcs = ["schema.zed"])
spicedb_relationships(name = "seed", schema = ":schema", srcs = ["seed.txt"])

spicedb_server(
    name          = "authz",
    schema        = ":schema",
    relationships = ":seed",
)

spicedb_health_check(name = "authz_health", server = ":authz")

itest_service(
    name         = "authz_svc",
    exe          = ":authz",
    health_check = ":authz_health",
)

service_test(
    name     = "api_test",
    test     = ":api_test_bin",
    services = [":authz_svc"],
)
```

In your service test:
```bash
# Source SpiceDB connection details written by spicedb_server
source "$TEST_TMPDIR/authz.env"

# Use the zed CLI via $ZED_BIN
result=$("$ZED_BIN" permission check document:doc1 read user:alice \
    --endpoint="$ZED_ENDPOINT" --token="$ZED_TOKEN" --insecure)
```

## Example: pod-to-pod (permission check in a test)

### Relationship file format

Each line in a relationship file is a SpiceDB tuple:
```
# Comments start with #
<object_type>:<object_id>#<relation>@<subject_type>:<subject_id>

# Examples:
document:report#owner@user:alice
document:report#viewer@user:bob
team:eng#member@user:alice
team:eng#member@user:bob

# Wildcards (all users of a type):
document:public#viewer@user:*
```

### Using a Go test

```python
load("@io_bazel_rules_go//go:def.bzl", "go_test")
load("@rules_spicedb//:defs.bzl", "spicedb_schema", "spicedb_test")

spicedb_schema(name = "schema", srcs = ["schema.zed"])

spicedb_test(
    name      = "authz_go_test",
    schema    = ":schema",
    test_rule = go_test,
    srcs      = ["authz_test.go"],
    deps      = [
        "@com_github_authzed_authzed_go//v1:go_default_library",
        "@org_golang_google_grpc//:go_default_library",
    ],
)
```

```go
// authz_test.go
package authz_test

import (
    "os"
    "testing"
    v1 "github.com/authzed/authzed-go/v1"
    "google.golang.org/grpc"
    "google.golang.org/grpc/credentials/insecure"
)

func TestPermissions(t *testing.T) {
    endpoint := os.Getenv("SPICEDB_GRPC_ADDR")
    token    := os.Getenv("SPICEDB_PRESHARED_KEY")

    client, err := v1.NewClient(endpoint,
        grpc.WithTransportCredentials(insecure.NewCredentials()),
        grpc.WithPerRPCCredentials(grpcutil.NewBearerTokenCredentials(token)),
    )
    // ... test permissions
}
```

## Binary acquisition

**System mode** (default, recommended for CI):
```python
spicedb.system(versions = ["1.30"])
```
Auto-detects `spicedb` and `zed` from `PATH`, then probes `/usr/local/bin`,
`/usr/bin`, `$HOME/.local/bin`. Fails at `bazel build` time with a clear
message if either binary is missing.

**Download mode** (hermetic, requires real SHA-256 checksums):
```python
spicedb.version(versions = ["1.30"])
```
Downloads tarballs from GitHub. SHA-256 checksums in `extensions.bzl` are
placeholders — run `tools/update_checksums.sh` before using this mode.

## Installing spicedb and zed

```sh
# macOS
brew install authzed/tap/spicedb authzed/tap/zed

# Fedora / RHEL
sudo dnf install spicedb zed

# Ubuntu / Debian (via Authzed apt repo)
# See https://authzed.com/docs/spicedb/getting-started/installing-spicedb

# Direct download
curl -L https://github.com/authzed/spicedb/releases/latest/download/spicedb_linux_amd64.tar.gz \
  | tar -xz -C ~/.local/bin
curl -L https://github.com/authzed/zed/releases/latest/download/zed_linux_amd64_gnu.tar.gz \
  | tar -xz -C ~/.local/bin
```

## Known limitations

- **spicedb + zed must be installed** (or SHA-256 sums pinned for download mode).
- **No caveated relationships in seed files** — use the SpiceDB gRPC API directly.
- **Windows not supported.**
- **Port allocation is TOCTOU** — retried up to 5 times on conflict.
