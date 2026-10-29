#!/usr/bin/env python3
"""Confirm one million no-op deliveries on this host, including receipt checks.

Each partition owns an independent TLS/AOF-always Redis and delivery runtime.
Partitions run concurrently on the SAME host; no external Redis is contacted.
The aggregate clock includes fixture startup and teardown as well as job work.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--binary', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--partitions', type=int, default=2)
parser.add_argument('--jobs', type=int, default=1_000_000)
parser.add_argument('--workers', type=int, default=int(os.environ.get('CRYSTAL_WORKERS', '2')))
parser.add_argument('--batch-size', type=int, default=128)
parser.add_argument('--capacity', type=int, default=512)
parser.add_argument('--producers', type=int, default=4)
parser.add_argument('--payload-bytes', type=int, default=64)
parser.add_argument('--require-target', action='store_true')
args = parser.parse_args()
if not 1 <= args.partitions <= 8 or not args.partitions <= args.jobs <= 1_000_000:
    parser.error('partitions must be 1..8; jobs must be partitions..1000000')
if not 1 <= args.workers <= 128 or not 1 <= args.batch_size <= min(128, args.capacity):
    parser.error('invalid workers/batch size/capacity')
if not args.batch_size <= args.capacity <= 1024 or not 1 <= args.producers <= 128 or not 1 <= args.payload_bytes <= 16384:
    parser.error('invalid capacity/producers/payload size')
root = Path(__file__).resolve().parents[1]
binary = args.binary.resolve(strict=True)
quota = Path('/sys/fs/cgroup/cpu.max')
memory = Path('/sys/fs/cgroup/memory.max')
metadata = dict(logical_cpus=os.cpu_count(), affinity_cpus=len(os.sched_getaffinity(0)),
                cgroup_cpu_max=quota.read_text().strip() if quota.exists() else None,
                cgroup_memory_max=memory.read_text().strip() if memory.exists() else None,
                binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                source_base=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(),
                working_tree_dirty=bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=root)))


def partition(index):
    count = args.jobs // args.partitions + (index < args.jobs % args.partitions)
    env = dict(os.environ, CRYSTAL_WORKERS=str(args.workers), BENCH_PROTOCOL='atomic',
               BENCH_JOBS=str(count), BENCH_BATCH_SIZE=str(args.batch_size), BENCH_CAPACITY=str(args.capacity),
               BENCH_PRODUCERS=str(args.producers), BENCH_PAYLOAD_BYTES=str(args.payload_bytes), BENCH_TIMEOUT='240')
    run = subprocess.run([sys.executable, str(root / 'scripts/run_integration.py'), '--timeout', '300',
                          '--probe', str(binary)], cwd=root, env=env, text=True,
                         capture_output=True, timeout=330)
    if run.returncode:
        raise RuntimeError(f'partition {index} failed:\n{run.stdout}\n{run.stderr}')
    record = [json.loads(line) for line in run.stdout.splitlines() if line.startswith('{')][-1]
    if not record['accepted'] == record['confirmed_completed'] == record['handler_executions'] == count:
        raise RuntimeError(f'partition {index} did not conserve jobs/executions')
    if record['tls'] is not True or record['appendfsync'] != 'always':
        raise RuntimeError('durability/transport settings changed')
    return dict(partition=index, **record)


started = time.monotonic()
with ThreadPoolExecutor(max_workers=args.partitions) as executor:
    runs = list(executor.map(partition, range(args.partitions)))
elapsed = time.monotonic() - started
completed = sum(run['confirmed_completed'] for run in runs)
report = dict(host=metadata, partitions=args.partitions, workers_per_partition=args.workers,
              elapsed_seconds_including_fixtures=elapsed, accepted=sum(run['accepted'] for run in runs),
              confirmed_completed=completed, completed_per_second=completed / elapsed,
              completed_per_minute=completed / elapsed * 60,
              million_completed_within_minute=completed >= 1_000_000 and elapsed <= 60, runs=runs)
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps({k: v for k, v in report.items() if k not in ('host', 'runs')}, indent=2), flush=True)
if args.require_target and not report['million_completed_within_minute']:
    raise SystemExit('one million completions within 60 seconds was not achieved')
