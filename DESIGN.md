# rules_spicedb Design

## Goals

1. **Hermetic** — each test gets its own SpiceDB instance; no shared state.
2. **Parallel-safe** — random port allocation; `--jobs=N` safe.
3. **Zero external infrastructure** — `spicedb serve-testing` is in-memory;
   no Postgres/MySQL backend needed.
4. **Consistent with rules_pg / rules_kind** — same provider chain, wrapper
   script, env file, and health check patterns.

## Provider chain

```
SpiceDBBinaryInfo          (spicedb + zed binaries + version)
  └─ SpiceDBSchemaInfo     (binary + ordered .zed files)
       └─ SpiceDBRelationshipsInfo  (schema + relationship tuple files)
            └─ consumed by spicedb_test / spicedb_server
```

This mirrors the rules_pg chain (`PostgresBinaryInfo → PostgresSchemaInfo →
PostgresSeedInfo`) and keeps the binary dependency out of the leaf rules.

## Why zed is a required binary

SpiceDB has no built-in CLI for writing schema or querying permissions from
shell scripts. The `zed` CLI fills that role:

- `zed import <yaml>` — writes schema + relationships in one gRPC call
- `zed permission check` — used in test scripts to verify permission resolution
- `zed schema read` — useful in test scripts for schema inspection

Without `zed`, test scripts would need to speak SpiceDB's gRPC protocol
directly, requiring language-specific client libraries in every test.

## Why `spicedb serve-testing`, not `spicedb serve`

`spicedb serve` requires a persistent datastore (Postgres, MySQL, CockroachDB,
or SQLite). `spicedb serve-testing`:

- Is entirely in-memory — no disk state, no database setup
- Starts in ~1 second (vs. 5–30 s for a backed server with migrations)
- Is designed for integration testing and is officially supported by Authzed
- Accepts **any** bearer token; each unique token gets its own isolated
  in-memory datastore (per-token isolation)

The trade-off: `serve-testing` state is lost on shutdown. This is a feature
for per-test isolation, not a bug.

## Per-token isolation

`spicedb serve-testing` gives each unique bearer token its own isolated
in-memory datastore. Two tests running concurrently on the same server process
with different tokens would not see each other's schema or relationships.
`rules_spicedb` does not exploit this — it starts a separate server process per
test — but it means the preshared key is not a security boundary. See
[Preshared key](#preshared-key) below.

## Schema and relationship loading — `zed import`

After the server is ready, the launcher calls `zed import` with a generated
YAML file containing the schema and relationships:

```yaml
schema: |-
  definition user {}
  definition document {
    relation owner: user
    permission read = owner
  }
relationships: |-
  document:doc1#owner@user:alice
```

**Alternatives considered:**

1. `spicedb serve-testing --load-configs` — this flag does not exist on
   `serve-testing` (as of v1.30). Schema must be loaded post-startup.
2. `zed schema write` + `zed relationship create` — two separate calls;
   individual relationship creates are O(N) RPCs. `zed import` does it in one.

## Port allocation

SpiceDB does not support `--socket-fd` (unlike PostgreSQL 14–17). The
launcher:

1. `socket.bind(('127.0.0.1', 0))` → get port → close socket
2. Pass port to `spicedb serve-testing --grpc-addr=:PORT`
3. Retry on "address already in use" (max 5 attempts)

This is the same approach as rules_pg uses for PostgreSQL 18+.

### Readonly gRPC port

`spicedb serve-testing` always starts a second, readonly gRPC server in
addition to the main one. By default it binds to `:50052`, which causes
"address already in use" failures when multiple tests run in parallel.

The launcher allocates a **second** random port and passes it via
`--readonly-grpc-addr=:READONLY_PORT`. Both ports are randomised; retries
cover conflicts on either.

## Readiness detection

The launcher polls via a raw TCP connect to the main gRPC port until the
connection succeeds (max 30 s, 0.5 s between attempts). This is simpler and
more reliable than calling `zed schema read`:

- `zed schema read` requires the server to have accepted connections and
  have its schema API fully initialised; in practice TCP connect and gRPC
  ready are almost simultaneous for `serve-testing`.
- A raw TCP connect has no auth dependencies and no possibility of a zed
  version mismatch causing a spurious timeout.

## Test mode vs. server mode

**Test mode** (`RULES_SPICEDB_MODE=test`):

```
wrapper.sh → launcher.py → spicedb serve-testing
                         → zed import
                         → os.execve(test_binary)   ← launcher becomes test binary
                                                       SpiceDB is an orphan child;
                                                       killed by Bazel's process group
```

`os.execve` replaces the launcher process with the test binary. SpiceDB
continues running as a child process until Bazel's test harness kills the
entire process group when the test exits.

**Server mode** (`RULES_SPICEDB_MODE=server`):

```
wrapper.sh → launcher.py → spicedb serve-testing
                         → zed import
                         → write $TEST_TMPDIR/<name>.env  ← readiness signal
                         → signal.pause()
                         → SIGTERM → kill spicedb → exit 0
```

The `rules_itest` service manager sends SIGTERM to all services after the
test binary exits.

## Env file protocol

`spicedb_server` writes `$TEST_TMPDIR/<name>.env` atomically (temp file +
`os.replace`) after all setup is complete. The file contains:

```
SPICEDB_GRPC_ADDR=localhost:PORT
SPICEDB_PRESHARED_KEY=<key>
ZED_ENDPOINT=localhost:PORT
ZED_TOKEN=<key>
ZED_INSECURE=true
ZED_BIN=/path/to/zed
```

Atomic write (temp file + `os.replace`) means the file either doesn't exist or
is fully written — no partial reads. `spicedb_health_check` exits 0 iff the
file exists, which is the readiness signal for `rules_itest`.

`ZED_*` variables are convenience aliases so test scripts can call `zed`
without repeating connection flags on every command.

## Preshared key

`rules_spicedb` uses a fixed default key (`"rules_spicedb_test_key"`) for all
test instances. This is intentional:

- `spicedb serve-testing` is not accessible outside the local loopback
- Tests are single-machine, not distributed
- A fixed key simplifies the public API (no key generation needed)

Users can override with `preshared_key = "..."` on `spicedb_test` or
`spicedb_server`.

## Binary acquisition

Two modes, mirroring rules_pg and rules_kind:

| Mode        | Mechanism                                        | Use case                    |
|-------------|--------------------------------------------------|-----------------------------|
| `system()`  | `rctx.symlink()` to host-installed binary        | CI with pre-installed tools |
| `version()` | `rctx.download_and_extract()` from GitHub        | Hermetic / air-gapped builds|

Both `spicedb` and `zed` are discovered together (they share a version pair)
and stored in the same repository rule per platform. Auto-detection probes
`PATH` first, then `/usr/local/bin`, `/usr/bin`, `$HOME/.local/bin`.

## What was NOT implemented

- **Caveated relationships in seed files** — the tuple format
  `object:id#relation@subject:id` does not carry caveat expressions. Add
  caveated relationships via the SpiceDB gRPC API in the test binary.
- **Multi-tenant namespaces** — `serve-testing` uses a single in-memory store
  per server instance (namespace isolation is per-token, not per-request).
- **Custom SpiceDB config** — `serve-testing` has fixed configuration. For
  advanced scenarios, wrap `spicedb serve` with a real datastore in a custom
  `spicedb_server`-equivalent rule.
- **Windows** — no pre-built binary source for Windows; PRs welcome.
