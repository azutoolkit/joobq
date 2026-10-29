#!/usr/bin/env python3
"""Run with run_integration.py --probe: owned TLS Redis, real worker process faults."""
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import uuid

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='joobq-leased-process-') as directory:
    temporary = Path(directory)
    binary = temporary / 'worker'
    subprocess.run(['crystal', 'build', str(root / 'spec/fixtures/leased_process_probe.cr'), '-o', str(binary)],
                   cwd=root, check=True, timeout=180)
    children = []

    def invoke(mode, env):
        result = subprocess.run([str(binary), mode], env=env, capture_output=True, text=True, timeout=20)
        if result.returncode:
            raise RuntimeError(result.stderr + result.stdout)
        return result.stdout

    def inspect(env):
        return json.loads(invoke('inspect', env).strip().splitlines()[-1])

    def worker(env):
        log = open(temporary / f'{uuid.uuid4()}.log', 'w')
        process = subprocess.Popen([str(binary), 'worker'], env=env, stdout=log, stderr=subprocess.STDOUT)
        children.append((process, log))
        return process

    def eventually(predicate, timeout=15):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(0.02)
        raise TimeoutError('process-fault invariant did not converge')

    results = []
    try:
        for fault, count in [('SIGKILL', 20), ('SIGTERM', 1)]:
            started = temporary / fault
            env = dict(os.environ, PROBE_NAMESPACE=f'process-{uuid.uuid4()}', PROBE_COUNT=str(count),
                       PROBE_STARTED=str(started), PROBE_WORK_MS='3000', PROBE_CAPACITY='1')
            invoke('seed', env)
            first = worker(env)
            eventually(started.exists)
            before = time.monotonic()
            first.send_signal(signal.SIGKILL if fault == 'SIGKILL' else signal.SIGTERM)
            status = first.wait(timeout=2)
            elapsed = time.monotonic() - before
            assert status == (-signal.SIGKILL if fault == 'SIGKILL' else 3), (fault, status)
            assert elapsed < 1.0, elapsed
            replacement_env = dict(env, PROBE_WORK_MS='0', PROBE_CAPACITY='4')
            replacement = worker(replacement_env)
            eventually(lambda: inspect(env)['completed'] == count)
            final = inspect(env)
            assert final['effects'] == count, final
            assert final['attempts'] >= count + 1, final
            replacement.send_signal(signal.SIGINT)
            assert replacement.wait(timeout=2) == 0
            results.append(dict(fault=fault, accepted=count, completed=final['completed'],
                                distinct_effects=final['effects'], attempts=final['attempts'],
                                shutdown_seconds=elapsed))
        print(json.dumps(dict(process_faults=results)))
    finally:
        for child, log in children:
            if child.poll() is None:
                child.kill()
            child.wait(timeout=5)
            log.close()
