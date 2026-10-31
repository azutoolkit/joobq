#!/usr/bin/env python3
"""Run released documentation examples against disposable loopback Redis.

Install each examples/docs/<edition>/shard.yml with `shards install --frozen`
first, or pass an existing fixture's lib directory with --dependencies.
No application Redis endpoint or credentials are inherited.
"""
import argparse
import contextlib
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
CASES = {
    "core": [("first_job", "Processed order 42", True),
             ("thin_job", "Order 42: 2500 cents", True),
             ("lifecycle", "PASS delayed retry DLQ replay shutdown", False)],
    "pro": [("first_workflow", "Processed order 42", False),
            ("workflow_dsl", "Receipt: Processed order 42", False),
            ("approval_workflow", "Approved order 42", False),
            ("compensation_workflow", "PASS failed payment released its reservation", False),
            ("production_worker", "Worker ready", True),
            ("coordination", "PASS batch uniqueness concurrent rate limit", False),
            ("observability", "PASS completion metrics collection shutdown", False)],
}


# Readiness alone is not worker health: exercise a separate producer before SIGTERM.
PROBES = {"production_worker": ("worker_probe", "Processed order 42")}

def stop(process, grace=5):
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=grace)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5)


def launch(command, cwd, env, log):
    return subprocess.Popen(command, cwd=cwd, env=env, stdout=log,
                            stderr=subprocess.STDOUT, start_new_session=True)


def tail(path):
    with path.open("rb") as log:
        log.seek(max(0, path.stat().st_size - 12_000))
        return log.read().decode(errors="replace")


def compile_example(name, workspace, env):
    log_path = workspace / f"{name}.build.log"
    with log_path.open("wb") as log:
        process = launch(["crystal", "build", f"{name}.cr", "--error-trace", "-o", name], workspace, env, log)
        try:
            code = process.wait(timeout=180)
        except subprocess.TimeoutExpired:
            raise RuntimeError(f"Compilation timed out: {name}") from None
        finally:
            stop(process)
    if code:
        raise RuntimeError(tail(log_path))


@contextlib.contextmanager
def redis_server(workspace, env):
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    directory = workspace / "redis"
    directory.mkdir()
    log_path = workspace / "redis.log"
    with log_path.open("wb") as log:
        process = launch(["redis-server", "--bind", "127.0.0.1", "--port", str(port),
                          "--save", "", "--appendonly", "yes", "--appendfsync", "always",
                          "--maxmemory-policy", "noeviction", "--dir", str(directory)], workspace, env, log)
        try:
            for _ in range(100):
                if process.poll() is not None:
                    raise RuntimeError(tail(log_path))
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=0.2) as connection:
                        connection.sendall(b"*1\r\n$4\r\nPING\r\n")
                        if connection.recv(128) == b"+PONG\r\n":
                            break
                except OSError:
                    pass
                time.sleep(0.05)
            else:
                raise RuntimeError("Disposable Redis did not become ready")
            # A known local config prevents discovery of a developer/system config.
            (workspace / "joobq.yml").write_text("joobq: {}\n")
            yield {**env, "REDIS_URL": f"redis://127.0.0.1:{port}/0", "REDIS_POOL_SIZE": "20"}
        finally:
            stop(process)


def run_example(name, expected, signal_after_output, workspace, env):
    log_path = workspace / f"{name}.log"
    started = time.monotonic()
    with log_path.open("wb") as log:
        process = launch([str(workspace / name)], workspace, env, log)
        try:
            deadline = started + 35
            signaled = False
            while process.poll() is None:
                if log_path.stat().st_size > 10 * 1024 * 1024:
                    raise RuntimeError(f"Unbounded example output: {name}")
                if time.monotonic() > deadline:
                    raise RuntimeError(f"Example timed out: {name}\n{tail(log_path)}")
                if signal_after_output and not signaled and expected in tail(log_path):
                    if probe := PROBES.get(name):
                        run_example(probe[0], probe[1], False, workspace, env)
                    process.send_signal(signal.SIGTERM)
                    signaled = True
                time.sleep(0.05)
            if process.returncode or expected not in tail(log_path) or (signal_after_output and not signaled):
                raise RuntimeError(f"Example failed: {name} (exit {process.returncode})\n{tail(log_path)}")
        finally:
            stop(process)
    print(f"PASS {name}: {time.monotonic() - started:.2f}s", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--edition", choices=CASES, required=True)
    parser.add_argument("--dependencies", type=Path, help="Already installed lib directory")
    parser.add_argument("--pro-source", type=Path, help="Authorized checkout of the documented Pro release")
    args = parser.parse_args()
    fixture = ROOT / "examples" / "docs" / args.edition
    dependencies = (args.dependencies or fixture / "lib").resolve()
    if not dependencies.is_dir():
        parser.error(f"Install the frozen fixture dependencies first: {dependencies}")
    if args.pro_source:
        if args.edition != "pro":
            parser.error("--pro-source requires --edition pro")
        commit = subprocess.check_output(["git", "-C", str(args.pro_source), "rev-parse", "HEAD"], text=True).strip()
        if commit != "92879b94a3be2580e749f3a0acc829b9276040dc":
            parser.error("--pro-source must be the documented v0.2.2 release")
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("REDIS_", "JOOBQ_")) and key not in ("RACK_ENV", "CRYSTAL_ENV")}
    with tempfile.TemporaryDirectory(prefix="joobq-docs-") as temporary:
        workspace = Path(temporary)
        lib = workspace / "lib"
        lib.mkdir()
        for dependency in dependencies.iterdir():
            (lib / dependency.name).symlink_to(dependency.resolve())
        if args.pro_source:
            (lib / "joobq_pro").symlink_to(args.pro_source.resolve())
        names = [name for name, _, _ in CASES[args.edition]]
        names += [PROBES[name][0] for name in names if name in PROBES]
        for name in names:
            shutil.copy2(fixture / f"{name}.cr", workspace)
            compile_example(name, workspace, env)
        with redis_server(workspace, env) as connected_env:
            for name, expected, signal_after_output in CASES[args.edition]:
                run_example(name, expected, signal_after_output, workspace, connected_env)


if __name__ == "__main__":
    main()
