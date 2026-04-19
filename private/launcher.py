#!/usr/bin/env python3
"""
rules_spicedb launcher.

Reads RULES_SPICEDB_MANIFEST (JSON) and performs the full SpiceDB lifecycle:
  start spicedb serve-testing → wait for gRPC ready (via zed schema read)
  → write schema (via zed import) → load relationships
  → (exec test binary | write env file + signal.pause())
  → SIGTERM → exit 0

Modes (set via RULES_SPICEDB_MODE):
  test   (default): _spicedb_setup() → os.execve(test_binary)
  server:           _spicedb_setup() → write $TEST_TMPDIR/<name>.env → signal.pause()

Environment exported to test binaries and the env file:
  SPICEDB_GRPC_ADDR     localhost:<port>
  SPICEDB_PRESHARED_KEY <preshared_key>
  ZED_ENDPOINT          localhost:<port>   (convenience alias for zed CLI)
  ZED_TOKEN             <preshared_key>    (convenience alias for zed CLI)
  ZED_INSECURE          true
  ZED_BIN               /path/to/zed
"""

import dataclasses
import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import time


# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------

def _log(msg):
    print(f"[rules_spicedb] {msg}", flush=True)


def _find_runfile(rel_path, workspace=""):
    """Resolve a Bazel short_path to an absolute path in the runfiles tree."""
    runfiles_dir = os.environ.get("RUNFILES_DIR", "")
    if not runfiles_dir:
        runfiles_dir = os.path.abspath(sys.argv[0]) + ".runfiles"

    if rel_path.startswith("../"):
        normalized = rel_path[3:]
    elif workspace:
        normalized = workspace + "/" + rel_path
    else:
        normalized = rel_path

    candidate = os.path.join(runfiles_dir, normalized)
    if os.path.exists(candidate):
        return os.path.abspath(candidate)

    raise FileNotFoundError(
        f"runfile not found: {rel_path!r}\n"
        f"  Looked in: {runfiles_dir}\n"
        f"  Normalized: {normalized}"
    )


def _ensure_executable(path):
    try:
        os.chmod(path, os.stat(path).st_mode | 0o111)
    except OSError:
        if not os.access(path, os.X_OK):
            raise


def _run(args, env=None, check=True, **kwargs):
    """Run a subprocess, print output on failure."""
    result = subprocess.run(
        args, capture_output=True, text=True, env=env, **kwargs)
    if check and result.returncode != 0:
        raise RuntimeError(
            f"command failed: {' '.join(str(a) for a in args)}\n"
            f"stdout: {result.stdout}\n"
            f"stderr: {result.stderr}"
        )
    return result


# ---------------------------------------------------------------------------
# Port allocation
# ---------------------------------------------------------------------------

def _find_free_port():
    """Bind to port 0 to find a free TCP port."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


# ---------------------------------------------------------------------------
# SpiceDB lifecycle
# ---------------------------------------------------------------------------

def _start_spicedb(spicedb_bin, grpc_port, preshared_key, log_file):
    """Start spicedb serve-testing. Returns a Popen object."""
    cmd = [
        spicedb_bin, "serve-testing",
        f"--grpc-addr=:{grpc_port}",
        f"--grpc-preshared-key={preshared_key}",
        "--skip-release-check",
    ]
    _log(f"starting spicedb serve-testing on port {grpc_port}...")
    return subprocess.Popen(
        cmd,
        stdout=open(log_file, "w"),
        stderr=subprocess.STDOUT,
    )


def _wait_spicedb_ready(zed_bin, endpoint, token, timeout=30):
    """Poll via zed schema read until SpiceDB is accepting requests."""
    _log("waiting for SpiceDB gRPC endpoint...")
    env = {**os.environ,
           "ZED_ENDPOINT": endpoint,
           "ZED_TOKEN": token,
           "ZED_INSECURE": "true"}
    deadline = time.monotonic() + timeout
    last_err = ""
    while time.monotonic() < deadline:
        result = subprocess.run(
            [zed_bin, "schema", "read"],
            capture_output=True, text=True, env=env,
        )
        if result.returncode == 0:
            _log("SpiceDB is ready")
            return
        last_err = (result.stderr or result.stdout).strip()
        time.sleep(0.5)
    raise TimeoutError(
        f"SpiceDB did not become ready within {timeout}s.\n"
        f"Last error: {last_err}"
    )


def _write_import_yaml(schema_files, relationship_files, yaml_path):
    """Generate a zed import YAML combining schema and relationships.

    Format:
      schema: |-
        <schema content>
      relationships: |-
        <tuple1>
        <tuple2>
    """
    schema_content = ""
    for f in schema_files:
        with open(f) as fp:
            schema_content += fp.read() + "\n"

    rel_content = ""
    for f in relationship_files:
        with open(f) as fp:
            for line in fp:
                stripped = line.strip()
                if stripped and not stripped.startswith("#"):
                    rel_content += stripped + "\n"

    lines = []
    if schema_content.strip():
        lines.append("schema: |-")
        for line in schema_content.splitlines():
            lines.append("  " + line)
        lines.append("")

    if rel_content.strip():
        lines.append("relationships: |-")
        for line in rel_content.splitlines():
            lines.append("  " + line)

    with open(yaml_path, "w") as f:
        f.write("\n".join(lines) + "\n")


def _load_schema_and_relationships(zed_bin, endpoint, token, schema_files,
                                   relationship_files, tmpdir):
    """Write schema and relationships via zed import."""
    if not schema_files and not relationship_files:
        _log("no schema or relationships to load")
        return

    yaml_path = os.path.join(tmpdir, "spicedb_import.yaml")
    _write_import_yaml(schema_files, relationship_files, yaml_path)

    env = {**os.environ,
           "ZED_ENDPOINT": endpoint,
           "ZED_TOKEN": token,
           "ZED_INSECURE": "true"}
    _run([zed_bin, "import", yaml_path], env=env)

    parts = []
    if schema_files:
        parts.append(f"{len(schema_files)} schema file(s)")
    if relationship_files:
        parts.append(f"{len(relationship_files)} relationship file(s)")
    _log("loaded " + " and ".join(parts))


def _stop_spicedb(proc):
    """Terminate the spicedb process gracefully."""
    _log("stopping SpiceDB...")
    try:
        proc.terminate()
        proc.wait(timeout=10)
        _log("SpiceDB stopped")
    except Exception as e:
        _log(f"warning: SpiceDB shutdown failed: {e}")
        proc.kill()


# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

@dataclasses.dataclass
class _SpiceDBState:
    grpc_addr:     str
    preshared_key: str
    proc:          object   # Popen
    zed_bin:       str


def _spicedb_setup(m, workspace, test_tmpdir):
    """Start SpiceDB, write schema and relationships. Returns _SpiceDBState."""
    spicedb_bin = _find_runfile(m["spicedb_bin"], workspace)
    zed_bin     = _find_runfile(m["zed_bin"], workspace)
    _ensure_executable(spicedb_bin)
    _ensure_executable(zed_bin)

    preshared_key = m.get("preshared_key", "rules_spicedb_test_key")

    schema_files = [_find_runfile(p, workspace) for p in m.get("schema_files", [])]
    rel_files    = [_find_runfile(p, workspace) for p in m.get("relationship_files", [])]

    # Find a free port and start the server.  Retry up to 5 times on port
    # conflicts (TOCTOU race between _find_free_port and server bind).
    max_attempts = 5
    proc = None
    for attempt in range(max_attempts):
        grpc_port = _find_free_port()
        endpoint  = f"localhost:{grpc_port}"
        log_file  = os.path.join(test_tmpdir, "spicedb.log")

        proc = _start_spicedb(spicedb_bin, grpc_port, preshared_key, log_file)
        try:
            _wait_spicedb_ready(zed_bin, endpoint, preshared_key, timeout=30)
        except TimeoutError:
            proc.terminate()
            proc.wait()
            with open(log_file) as fh:
                log = fh.read()
            if "address already in use" in log.lower() and attempt < max_attempts - 1:
                _log(f"port {grpc_port} conflict on attempt {attempt + 1}, retrying...")
                continue
            # Non-retryable error: print the full log and fail.
            raise RuntimeError(
                f"SpiceDB failed to start (port {grpc_port}):\n{log}"
            )
        break

    _load_schema_and_relationships(
        zed_bin, endpoint, preshared_key, schema_files, rel_files, test_tmpdir)

    return _SpiceDBState(
        grpc_addr     = endpoint,
        preshared_key = preshared_key,
        proc          = proc,
        zed_bin       = zed_bin,
    )


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    manifest_path = os.environ.get("RULES_SPICEDB_MANIFEST", "")
    if not manifest_path:
        print("[rules_spicedb] ERROR: RULES_SPICEDB_MANIFEST is not set",
              file=sys.stderr)
        sys.exit(1)

    mode        = os.environ.get("RULES_SPICEDB_MODE", "test")
    server_name = os.environ.get("RULES_SPICEDB_SERVER_NAME", "spicedb_server")
    test_tmpdir = os.environ.get("TEST_TMPDIR") or tempfile.mkdtemp()

    with open(manifest_path) as f:
        m = json.load(f)

    workspace = m["workspace"]
    state = _spicedb_setup(m, workspace, test_tmpdir)

    extra_env = {
        "SPICEDB_GRPC_ADDR":     state.grpc_addr,
        "SPICEDB_PRESHARED_KEY": state.preshared_key,
        "ZED_ENDPOINT":          state.grpc_addr,
        "ZED_TOKEN":             state.preshared_key,
        "ZED_INSECURE":          "true",
        "ZED_BIN":               state.zed_bin,
    }

    if mode == "test":
        test_bin = os.environ.get("RULES_SPICEDB_TEST_BINARY", "")
        if not test_bin:
            print("[rules_spicedb] ERROR: RULES_SPICEDB_TEST_BINARY is not set",
                  file=sys.stderr)
            _stop_spicedb(state.proc)
            sys.exit(1)

        env = os.environ.copy()
        env.update(extra_env)

        # SpiceDB is a child process; it will be killed when the test process
        # group exits (Bazel handles this via cgroups / process groups).
        _log(f"starting test binary: {os.path.basename(test_bin)}")
        os.execve(test_bin, [test_bin], env)

    else:  # server mode
        output_env = os.path.join(test_tmpdir, f"{server_name}.env")

        def _shutdown(signum, _frame):
            _log(f"received signal {signum}, shutting down...")
            _stop_spicedb(state.proc)
            sys.exit(0)

        signal.signal(signal.SIGTERM, _shutdown)
        signal.signal(signal.SIGINT, _shutdown)

        # Write env file atomically once fully ready.
        tmp = output_env + ".tmp"
        with open(tmp, "w") as f:
            for k, v in extra_env.items():
                f.write(f"{k}={v}\n")
        os.replace(tmp, output_env)
        _log(f"server ready — env file written: {output_env}")

        try:
            while True:
                signal.pause()
        except Exception:
            _stop_spicedb(state.proc)
            raise


if __name__ == "__main__":
    main()
