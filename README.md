# rules_spicedb

Bazel rules for [SpiceDB](https://authzed.com/spicedb) — two families
of primitives:

- **Test-time** (v0.1): hermetic, parallel-safe SpiceDB instances
  via `spicedb serve-testing` (in-memory, ~1s startup). Designed for
  `*_test` targets and `rules_itest` compositions.
- **Install-time** (v0.2): `spicedb_install` /
  `spicedb_install_health_check` deploys the
  [spicedb-operator](https://github.com/authzed/spicedb-operator) to
  a real cluster. Drops into `itest_service.exe` /
  `.health_check`. Sibling to the test primitives in the same
  package.

## Features

### Test-time (v0.1)

- **`spicedb_test`** — wrap any `*_test` rule with an ephemeral
  SpiceDB instance; schema and relationships loaded before the test
  binary runs.
- **`spicedb_server`** + **`spicedb_health_check`** — long-running
  server for `rules_itest` multi-service tests.
- **Parallel-safe** — every test target gets its own server on a
  unique port.
- **`~1 s` startup** — in-memory, no disk setup.
- **System or downloaded binaries** — symlink host-installed
  `spicedb` / `zed` or download tarballs from GitHub.

### Install-time (v0.2)

- **`spicedb_install`** — `kubectl_apply` over a vendored
  spicedb-operator bundle. Wait shape: `spicedb-operator`
  Deployment + `spicedbclusters.authzed.com` CRD. Pinned to operator
  `v1.25.0`.
- **`spicedb_install_health_check`** — paired readiness probe (named
  with `_install_` to avoid colliding with the test-time
  `spicedb_health_check`).
- **Vendored `bundle.yaml`** — pinned URL + sha256 in
  `tools/versions.bzl`. Re-render via
  `bash tools/render_spicedb_operator.sh <version>`.
- See [Install primitives](#install-primitives) below for usage.

## Quick start

### 1. Declare the dependency

**MODULE.bazel (Bzlmod)**:
```python
bazel_dep(name = "rules_spicedb", version = "0.3.0")

spicedb = use_extension("@rules_spicedb//:extensions.bzl", "spicedb")
# v0.3+: spicedb.version() fetches hermetic spicedb + zed binaries
# from authzed's GitHub releases. No host install required.
spicedb.version(versions = ["1.52"])
use_repo(spicedb,
    "spicedb_1_52_linux_amd64",
    "spicedb_1_52_darwin_arm64",
    "spicedb_1_52_darwin_amd64",
)
```

Use `spicedb.system(versions = [...])` instead if you want to reuse the host's `spicedb` + `zed` installs (e.g. `brew install authzed/tap/spicedb`). Both modes coexist per-minor-version; see [DESIGN.md](DESIGN.md).

**WORKSPACE (legacy)**:
```python
load("@rules_spicedb//:repositories.bzl", "spicedb_system_dependencies")
spicedb_system_dependencies(versions = ["1.52"])
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
result=$("$ZED_BIN" permission check document:doc1 write user:alice \
    --endpoint="$SPICEDB_GRPC_ADDR" \
    --token="$SPICEDB_PRESHARED_KEY" \
    --insecure)

echo "$result" | grep -q "true" || { echo "FAIL: alice should have write"; exit 1; }
echo "PASS"
```

## Complex example: platform access control

This example models a GitHub-style permission system across three resource
types — organizations, teams, and repositories — with hierarchical permission
inheritance. It mirrors the test in `tests/schema/platform.zed`.

### Schema

**schema/platform.zed**:
```
definition user {}

definition organization {
    relation admin:  user
    relation member: user

    permission admin_access = admin
    permission access       = member + admin
}

definition team {
    relation org:    organization
    relation member: user

    // Org admins implicitly lead every team.
    permission membership = member + org->admin_access
}

definition repository {
    relation org:         organization
    relation maintainer:  user
    relation writer:      user
    relation reader:      user
    relation reader_team: team

    // Org admins inherit full maintain rights across all repos.
    permission maintain = maintainer + org->admin_access

    // write > maintain
    permission write = writer + maintain

    // read is open to individual readers, team members, and anyone who can write.
    permission read = reader + reader_team->membership + write
}
```

### Relationships

**seed/platform.txt**:
```
# Organization
organization:acme#admin@user:alice
organization:acme#member@user:bob
organization:acme#member@user:charlie
organization:acme#member@user:dave
organization:acme#member@user:eve

# Team: backend (charlie + dave)
team:backend#org@organization:acme
team:backend#member@user:charlie
team:backend#member@user:dave

# Repo: api — bob maintains, eve reads, backend team reads
repository:api#org@organization:acme
repository:api#maintainer@user:bob
repository:api#reader@user:eve
repository:api#reader_team@team:backend

# Repo: private — org-admins only (no direct grants)
repository:private#org@organization:acme
```

### BUILD.bazel

```python
load("@rules_spicedb//:defs.bzl",
    "spicedb_schema", "spicedb_relationships", "spicedb_test")

spicedb_schema(
    name = "platform_schema",
    srcs = ["schema/platform.zed"],
)

spicedb_relationships(
    name   = "platform_seed",
    schema = ":platform_schema",
    srcs   = ["seed/platform.txt"],
)

spicedb_test(
    name          = "platform_access_test",
    schema        = ":platform_schema",
    relationships = ":platform_seed",
    srcs          = ["platform_access_test.sh"],
    size          = "medium",
)
```

### Test script

**platform_access_test.sh**:
```bash
#!/usr/bin/env bash
set -euo pipefail

require_env() { [[ -n "${!1:-}" ]] || { echo "ERROR: \$$1 not set" >&2; exit 1; }; }
require_env SPICEDB_GRPC_ADDR
require_env SPICEDB_PRESHARED_KEY
require_env ZED_BIN

PASS=0; FAIL=0

check_permission() {
    local object="$1" perm="$2" subject="$3" expected="${4:-true}"
    local result
    result=$("$ZED_BIN" permission check "$object" "$perm" "$subject" \
        --endpoint="$SPICEDB_GRPC_ADDR" --token="$SPICEDB_PRESHARED_KEY" --insecure 2>&1)
    if echo "$result" | grep -qi "$expected"; then
        echo "PASS  [$perm] $subject on $object → $expected"
        PASS=$(( PASS + 1 ))
    else
        echo "FAIL  [$perm] $subject on $object → expected $expected, got: $result" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

echo "=== Direct grants ==="
check_permission repository:api maintain user:bob true   # direct maintainer
check_permission repository:api write    user:bob true   # maintain ⊇ write
check_permission repository:api read     user:bob true   # maintain ⊇ read
check_permission repository:api read     user:eve true   # direct reader
check_permission repository:api write    user:eve false  # reader cannot write
check_permission repository:api maintain user:eve false  # reader cannot maintain

echo "=== Org admin inheritance ==="
check_permission repository:api     maintain user:alice true   # org admin
check_permission repository:private maintain user:alice true   # org admin on all repos
check_permission repository:private read     user:alice true
check_permission repository:private maintain user:bob   false  # bob is not org admin
check_permission repository:private read     user:bob   false

echo "=== Team delegation ==="
check_permission repository:api read  user:charlie true   # via team:backend
check_permission repository:api write user:charlie false  # teams only get read
check_permission repository:api read  user:dave    true   # via team:backend
check_permission repository:private read user:dave false  # team not in private

echo "=== Org admin leads all teams ==="
check_permission team:backend membership user:alice   true   # org admin
check_permission team:backend membership user:charlie true   # direct member
check_permission team:backend membership user:bob     false  # org member, not admin

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
echo "ALL PASS"
```

### What gets verified

| Check | Why |
|-------|-----|
| `bob maintain api` | Direct `maintainer` grant |
| `bob write/read api` | `maintain` subsumes `write` subsumes `read` |
| `eve read api` | Direct `reader` grant |
| `eve write/maintain api` — denied | No write/maintain grant |
| `alice maintain api/private` | Org admin → `org->admin_access` |
| `bob maintain/read private` — denied | Not org admin, no direct grant |
| `charlie/dave read api` | `team:backend` is `reader_team` on `api` |
| `charlie write api` — denied | Team only gets `read` |
| `dave read private` — denied | Team not listed on `private` |
| `alice membership backend` | Org admin inherits team membership |
| `bob membership backend` — denied | Org member, not admin |

## Install primitives

For deploying SpiceDB itself to a Kubernetes cluster (vs running
ephemeral instances in tests), v0.2 adds install-time primitives.

### `spicedb_install`

Vendors and applies the
[spicedb-operator](https://github.com/authzed/spicedb-operator)
`bundle.yaml`. The operator reconciles consumer-authored
`SpiceDBCluster` CRs into Deployments, Services, ConfigMaps —
the actual SpiceDB workload runs in pods the operator manages.

```python
load("@rules_spicedb//:defs.bzl",
     "spicedb_install", "spicedb_install_health_check")

spicedb_install(
    name = "spicedb_install_bin",
    namespace = "spicedb-operator",   # default
    wait_timeout = "300s",            # default
)

spicedb_install_health_check(
    name = "spicedb_install_health_bin",
)
```

Drops into `itest_service.exe` / `.health_check`:

```python
load("@rules_itest//:itest.bzl", "itest_service")
load("@rules_kind//:defs.bzl", "kind_cluster", "kind_health_check")
load("@rules_shell//shell:sh_binary.bzl", "sh_binary")

kind_cluster(name = "cluster", k8s_version = "1.32")
kind_health_check(name = "cluster_health", cluster = ":cluster")
itest_service(name = "kind_svc", exe = ":cluster", health_check = ":cluster_health")

spicedb_install(name = "spicedb_install_bin")
spicedb_install_health_check(name = "spicedb_install_health_bin")
sh_binary(name = "spicedb_install_wrapper",
          srcs = ["install_wrapper.sh"],
          data = [":spicedb_install_bin"])
sh_binary(name = "spicedb_install_health_wrapper",
          srcs = ["health_wrapper.sh"],
          data = [":spicedb_install_health_bin"])

itest_service(
    name = "spicedb_install_svc",
    exe = ":spicedb_install_wrapper",
    deps = [":kind_svc"],
    health_check = ":spicedb_install_health_wrapper",
)
```

After the install service is healthy, consumers apply their own
`SpiceDBCluster` CRs:

```yaml
apiVersion: authzed.com/v1alpha1
kind: SpiceDBCluster
metadata:
  name: my-spicedb
  namespace: my-app
spec:
  config:
    datastoreEngine: postgres        # or memory, cockroachdb, mysql
  # references a Secret with `preshared_key` (and `datastore_uri` for non-memory)
  secretName: my-spicedb-secret
```

The operator reconciles each SpiceDBCluster into a Deployment
named `<cluster>-spicedb` and a Service named `<cluster>` exposing
gRPC :50051 / HTTP :8443 / metrics :9090.

> **`SpiceDBCluster` CRD reference**: see
> [authzed/spicedb-operator config docs](https://github.com/authzed/spicedb-operator/blob/main/CONFIGURATION.md).
> The smoke fixture in `tests/install_smoke/cluster.yaml` shows
> the minimal memory-backend shape used by the in-tree CI.

### Production-shape backend

The smoke uses `datastoreEngine: memory` for simplicity (single
replica, ephemeral). Real production uses `postgres` or
`cockroachdb` — compose with
[`rules_cloudnativepg`](https://github.com/collider-bazel-extensions/rules_cloudnativepg)
or a managed-DB bring-your-own pattern.

### Naming asymmetry

Install primitives are named `spicedb_install` /
`spicedb_install_health_check` (not `spicedb_health_check`) to
avoid colliding with v0.1's `spicedb_health_check`, which pairs
with the test-time `spicedb_server`. Both health checks coexist;
pick the one matching your install vs test composition.

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

Declares relationship tuple files to load after the schema is written.

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

The following variables are injected into test binaries and written to the
`.env` file for `spicedb_server`:

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

result=$("$ZED_BIN" permission check document:doc1 read user:alice \
    --endpoint="$ZED_ENDPOINT" --token="$ZED_TOKEN" --insecure)
```

## Using a Go test

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

## Relationship file format

Each line in a relationship file is a SpiceDB tuple:
```
# Comments start with #
<object_type>:<object_id>#<relation>@<subject_type>:<subject_id>

# Examples:
document:report#owner@user:alice
document:report#viewer@user:bob
team:eng#member@user:alice

# Wildcards (all users of a type):
document:public#viewer@user:*
```

## Binary acquisition

**Hermetic mode (default in v0.3+, recommended for CI):**
```python
spicedb.version(versions = ["1.52"])
```
Downloads pre-built `spicedb` + `zed` tarballs from authzed's GitHub releases at the pinned sha256s. No host install required. SHA-256s in `extensions.bzl` come from each release's `checksums.txt`. Maintainer flow for bumping pinned versions: edit `_SPICEDB_VERSIONS` then push (or run `tools/update_checksums.sh`).

**System mode** (consumer opt-in):
```python
spicedb.system(versions = ["1.52"])
```
Reuses the host's `spicedb` + `zed` installs. Auto-detects from `PATH`, then probes `/usr/local/bin`, `/usr/bin`, `$HOME/.local/bin`. Fails at `bazel build` time with a clear message if either binary is missing. Useful when you want to pin to a specific patch version controlled outside rules_spicedb's release cycle.

Both modes coexist per minor-version. rules_spicedb's own `MODULE.bazel` uses `spicedb.version()` so CI runs on a bare `ubuntu-latest` runner with no host install.

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
