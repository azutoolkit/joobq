#!/usr/bin/env python3
"""Owned, disposable Redis only. Requires crystal, redis-server and redis-cli on PATH.
A worker process (A) with every job of a Core queue running is SIGKILLed, and a second process (B) starts at once,
inside A's heartbeat TTL, so its start-up recovery finds A still alive. B's reaper must put A's jobs back and B must run
each of them once, none lost, inside TTL + reaper interval (plus SLACK for scheduling and the heartbeat's last beat).
Fails otherwise.
"""
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
JOBS, TTL_MS, INTERVAL_MS, SLACK = 12, 3000, 1000, 2.0
BOUND = (TTL_MS + INTERVAL_MS) / 1000 + SLACK
JOB_SECONDS = 2


def main(ttl_ms=TTL_MS, interval_ms=INTERVAL_MS):
    with tempfile.TemporaryDirectory(prefix="joobq-crash-recovery-") as temp:
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        work = Path(temp) / "work"
        work.mkdir()
        env = {key: value for key, value in os.environ.items() if not key.startswith(("REDIS_", "JOOBQ_SPEC_"))}
        env.update(JOOBQ_ENV="test", REDIS_HOST="127.0.0.1", REDIS_PORT=str(port), PROBE_DIR=str(work),
                   PROBE_JOBS=str(JOBS), PROBE_JOB_SECONDS=str(JOB_SECONDS), PROBE_TTL_MS=str(ttl_ms),
                   PROBE_INTERVAL_MS=str(interval_ms), PROBE_LIMIT=str(BOUND + JOB_SECONDS + 20))
        binary = str(Path(temp) / "probe")
        subprocess.run(["crystal", "build", str(ROOT / "spec/fixtures/crash_recovery_probe.cr"), "-o", binary],
                       cwd=ROOT, env=env, check=True, timeout=240)
        with open(Path(temp) / "redis.log", "wb") as log:
            server = subprocess.Popen(["redis-server", "--bind", "127.0.0.1", "--port", str(port), "--dir", temp,
                                       "--save", "", "--appendonly", "yes", "--appendfsync", "always"],
                                      stdout=log, stderr=subprocess.STDOUT)
            first = second = None
            try:
                deadline = time.monotonic() + 10
                while subprocess.run(["redis-cli", "-h", "127.0.0.1", "-p", str(port), "ping"],
                                     capture_output=True, timeout=2).stdout.strip() != b"PONG":
                    if time.monotonic() > deadline:
                        raise TimeoutError("Redis startup timeout")
                    time.sleep(0.05)
                first = subprocess.Popen([binary], env=dict(env, PROBE_SEED="1"))
                deadline = time.monotonic() + 30
                while len(list(work.glob("attempt-*"))) < JOBS:
                    if time.monotonic() > deadline or first.poll() is not None:
                        raise SystemExit("FAIL: the jobs did not start in the first process")
                    time.sleep(0.02)
                killed = time.time()
                first.send_signal(signal.SIGKILL)
                first.wait(timeout=5)
                assert not list(work.glob("done-*")), "a job of the killed process finished"
                second = subprocess.Popen([binary], env=env)
                while second.poll() is None and time.time() - killed < BOUND + JOB_SECONDS + 15:
                    time.sleep(0.05)
                finished = time.time() - killed
                first_pid = first.pid
                reruns = {}
                for path in work.glob("attempt-*"):
                    _, number, pid = path.name.split("-")
                    if int(pid) != first_pid:
                        reruns.setdefault(number, []).append(path.stat().st_mtime - killed)
                if second.poll() != 0:
                    raise SystemExit(f"FAIL: {len(reruns)}/{JOBS} jobs re-run, process B did not finish "
                                     f"{finished:.1f}s after the kill")
                completions = {}
                for path in work.glob("done-*"):
                    completions.setdefault(path.name.split("-")[1], []).append(path.name.split("-")[2])
                assert sorted(completions, key=int) == [str(i) for i in range(JOBS)], f"jobs lost: {completions}"
                assert all(len(pids) == 1 for pids in completions.values()), f"a job ran to its end twice: {completions}"
                assert all(len(times) == 1 for times in reruns.values()), f"a job re-ran twice in B: {reruns}"
                started = max(max(times) for times in reruns.values())
                if started > (ttl_ms + interval_ms) / 1000 + SLACK:
                    raise SystemExit(f"FAIL: the last job restarted {started:.1f}s after the kill; "
                                     f"the bound is TTL + interval = {(ttl_ms + interval_ms) / 1000:.1f}s + {SLACK}s")
                print(f"PASS: {JOBS}/{JOBS} jobs re-run once by the second process, the last {started:.1f}s after the "
                      f"SIGKILL (bound {(ttl_ms + interval_ms) / 1000:.1f}s), all done in {finished:.1f}s")
            finally:
                for child in (first, second):
                    if child is not None and child.poll() is None:
                        child.kill()
                        child.wait(timeout=5)
                server.terminate()
                try:
                    server.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    server.kill()


if __name__ == "__main__":
    main()
