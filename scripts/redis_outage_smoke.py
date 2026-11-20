#!/usr/bin/env python3
"""Owned, disposable Redis only. Requires crystal, redis-server and redis-cli on PATH.
A live worker process loses Redis (SIGKILL, AOF restart) while its jobs run, and must finish every job without
being restarted: it re-drives the copies whose outcome it could not store. Fails unless all jobs are done within
LIMIT seconds after Redis is back.
"""
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
JOBS, LIMIT, OUTAGE = 12, 30, 6

with tempfile.TemporaryDirectory(prefix="joobq-redis-outage-") as temp:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    work = Path(temp) / "work"
    work.mkdir()
    env = {key: value for key, value in os.environ.items() if not key.startswith(("REDIS_", "JOOBQ_SPEC_"))}
    env.update(JOOBQ_ENV="test", REDIS_HOST="127.0.0.1", REDIS_PORT=str(port), PROBE_DIR=str(work),
               PROBE_JOBS=str(JOBS), PROBE_JOB_SECONDS="3", PROBE_LIMIT=str(LIMIT + 60))
    binary = str(Path(temp) / "probe")
    subprocess.run(["crystal", "build", str(ROOT / "spec/fixtures/redis_outage_probe.cr"), "-o", binary],
                   cwd=ROOT, env=env, check=True, timeout=240)
    command = ["redis-server", "--bind", "127.0.0.1", "--port", str(port), "--dir", temp,
               "--save", "", "--appendonly", "yes", "--appendfsync", "always"]

    def start(log):
        server = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            ping = subprocess.run(["redis-cli", "-h", "127.0.0.1", "-p", str(port), "ping"], capture_output=True, timeout=2)
            if ping.stdout.strip() == b"PONG":
                return server
            time.sleep(0.05)
        server.kill()
        raise TimeoutError("Redis startup timeout")

    def done():
        return len(list(work.glob("done-*")))

    with open(Path(temp) / "redis.log", "wb") as log:
        server = start(log)
        probe = None
        try:
            probe = subprocess.Popen([binary], env=env)
            deadline = time.monotonic() + 30
            while len(list(work.glob("started-*"))) < JOBS:
                if time.monotonic() > deadline or probe.poll() is not None:
                    raise SystemExit("FAIL: the jobs did not start")
                time.sleep(0.05)
            server.kill()  # SIGKILL while the jobs run; they end while Redis is away
            server.wait(timeout=5)
            time.sleep(OUTAGE)
            server = start(log)
            back = time.monotonic()
            while probe.poll() is None and time.monotonic() - back < LIMIT:
                time.sleep(0.1)
            if probe.poll() != 0:
                raise SystemExit(f"FAIL: {done()}/{JOBS} jobs ran but not all settled {LIMIT}s after Redis returned")
            print(f"PASS: {JOBS}/{JOBS} jobs done {time.monotonic() - back:.1f}s after Redis returned, no restart")
        finally:
            if probe is not None and probe.poll() is None:
                probe.kill()
                probe.wait(timeout=5)
            if server.poll() is None:
                server.terminate()
                try:
                    server.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    server.kill()
