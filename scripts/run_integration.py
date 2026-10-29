#!/usr/bin/env python3
"""Run specs against three owned Redis servers (plain, second-store and TLS).
Requires crystal, openssl, redis-server and redis-cli on PATH. Never uses a supplied
Redis address. A failed fixture, missing spec summary or pending test fails the run.
"""
import argparse
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--url', action='store_true', help='exercise REDIS_URL configuration')
parser.add_argument('--timeout', type=int, default=600)
parser.add_argument('command', nargs=argparse.REMAINDER)
args = parser.parse_args()
command = args.command or ['crystal', 'spec']
if command[0] == '--':
    command = command[1:]
if not command or args.timeout <= 0:
    parser.error('a command and positive timeout are required')


def run(argv, **kwargs):
    return subprocess.run(argv, check=True, timeout=30, capture_output=True, **kwargs)


with tempfile.TemporaryDirectory(prefix='joobq-integration-') as temporary:
    root = Path(temporary)
    run(['openssl', 'req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1',
         '-nodes', '-keyout', 'ca.key', '-out', 'ca.pem', '-days', '2', '-subj', '/CN=joobq-test-ca'], cwd=root)
    run(['openssl', 'req', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1', '-nodes',
         '-keyout', 'srv.key', '-out', 'srv.csr', '-subj', '/CN=localhost'], cwd=root)
    (root / 'ext.cnf').write_text('subjectAltName=DNS:localhost,IP:127.0.0.1\n')
    run(['openssl', 'x509', '-req', '-in', 'srv.csr', '-CA', 'ca.pem', '-CAkey', 'ca.key',
         '-CAcreateserial', '-out', 'srv.pem', '-days', '2', '-extfile', 'ext.cnf'], cwd=root)
    processes, logs, ports = [], [], []
    child = None
    try:
        for index in range(3):
            with socket.socket() as sock:
                sock.bind(('127.0.0.1', 0))
                port = sock.getsockname()[1]
            if port in ports:
                raise RuntimeError('port allocation collision')
            ports.append(port)
            directory = root / str(index)
            directory.mkdir()
            log = open(directory / 'redis.log', 'wb')
            logs.append(log)
            server = ['redis-server', '--bind', '127.0.0.1', '127.0.0.2', '--port', str(port if index < 2 else 0),
                      '--dir', str(directory), '--save', '', '--appendonly', 'yes', '--appendfsync', 'always',
                      '--enable-debug-command', 'yes']
            ping = ['redis-cli', '-h', '127.0.0.1', '-p', str(port)]
            if index == 2:
                server += ['--tls-port', str(port), '--tls-cert-file', str(root / 'srv.pem'),
                           '--tls-key-file', str(root / 'srv.key'), '--tls-ca-cert-file', str(root / 'ca.pem'),
                           '--tls-auth-clients', 'no']
                ping += ['--tls', '--cacert', str(root / 'ca.pem')]
            process = subprocess.Popen(server, stdout=log, stderr=subprocess.STDOUT)
            processes.append(process)
            deadline = time.monotonic() + 10
            while True:
                if process.poll() is not None:
                    raise RuntimeError((directory / 'redis.log').read_text())
                reply = subprocess.run(ping + ['ping'], capture_output=True, timeout=2)
                if reply.stdout.strip() == b'PONG':
                    break
                if time.monotonic() >= deadline:
                    raise TimeoutError('owned Redis did not become ready')
                time.sleep(0.05)
        env = {k: v for k, v in os.environ.items() if not k.startswith(('REDIS_', 'JOOBQ_SPEC_'))}
        env.update(JOOBQ_ENV='test', REDIS_HOST='127.0.0.1', REDIS_PORT=str(ports[0]),
                   JOOBQ_SPEC_SECOND_REDIS_PORT=str(ports[1]),
                   JOOBQ_SPEC_TLS_REDIS_URL=f'rediss://localhost:{ports[2]}',
                   JOOBQ_SPEC_TLS_CA_FILE=str(root / 'ca.pem'))
        if args.url:
            env['REDIS_URL'] = f'redis://127.0.0.1:{ports[0]}/0'
        print(run(['redis-server', '--version']).stdout.decode().strip(), flush=True)
        print(f'Integration: {command}; workers={env.get("CRYSTAL_WORKERS", "default")}; url={args.url}', flush=True)
        child = subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                 text=True, start_new_session=True)
        output, _ = child.communicate(timeout=args.timeout)
        print(output, end='')
        if child.returncode:
            raise SystemExit(child.returncode)
        if re.search(r'BUG:|Unhandled exception in spawn|Invalid memory access', output):
            raise SystemExit('FAIL: runtime/fiber crash in otherwise passing test output')
        summary = re.search(r'(\d+) examples?, (\d+) failures?, (\d+) errors?, (\d+) pending', output)
        if not summary or int(summary[1]) == 0 or any(int(summary[i]) for i in (2, 3, 4)):
            raise SystemExit('FAIL: missing/empty spec summary or failed/pending examples')
    finally:
        if child is not None:
            # Include subprocess fixtures even when their parent exits abnormally.
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.wait()
        for process in reversed(processes):
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
        for log in logs:
            log.close()
