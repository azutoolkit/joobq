#!/usr/bin/env python3
"""Owned, disposable Redis only. Requires crystal, redis-server and redis-cli on PATH.
Tests acknowledged payload storage across process death with appendfsync=always;
not a replication/failover, disk-loss or exactly-once execution test.
"""
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="joobq-redis-restart-") as temp:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    env = {key: value for key, value in os.environ.items() if not key.startswith(("REDIS_", "JOOBQ_SPEC_"))}
    env.update(JOOBQ_ENV="test", REDIS_HOST="127.0.0.1", REDIS_PORT=str(port))
    binary = str(Path(temp) / "probe")
    subprocess.run(["crystal", "build", str(ROOT / "spec/fixtures/redis_restart_probe.cr"), "-o", binary],
                   cwd=ROOT, env=env, check=True, timeout=180)
    command = ["redis-server", "--bind", "127.0.0.1", "--port", str(port), "--dir", temp,
               "--save", "", "--appendonly", "yes", "--appendfsync", "always"]
    def start(log):
        server = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                if server.poll() is not None:
                    raise RuntimeError("owned Redis failed to start; inspect its log")
                ping = subprocess.run(["redis-cli", "-h", "127.0.0.1", "-p", str(port), "ping"],
                                      capture_output=True, timeout=2)
                if ping.stdout.strip() == b"PONG":
                    return server
                time.sleep(0.05)
            raise TimeoutError("Redis startup timeout")
        except BaseException:
            if server.poll() is None:
                server.kill()
            server.wait(timeout=5)
            raise
    with open(Path(temp) / "redis.log", "wb") as log:
        server = start(log)
        try:
            subprocess.run([binary, "seed"], env=env, check=True, timeout=30)
            server.kill()  # SIGKILL: no graceful save or shutdown.
            server.wait(timeout=5)
            server = start(log)
            subprocess.run([binary, "verify"], env=env, check=True, timeout=30)
        finally:
            if server.poll() is None:
                server.terminate()
                try:
                    server.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait(timeout=5)
