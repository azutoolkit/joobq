#!/usr/bin/env python3
"""Sequential isolated load runs; each run uses concurrent producers/workers.
A passing exit confirms conservation, not the throughput/duration release gates.
"""
import argparse
import json
import os
from pathlib import Path
import statistics
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--binary', type=Path, required=True)
parser.add_argument('--jobs', type=int, default=10000)
parser.add_argument('--repeats', type=int, default=3)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
if args.repeats < 1 or args.jobs < 1:
    parser.error('positive repeats/jobs required')
root = Path(__file__).resolve().parent.parent
binary = args.binary.resolve(strict=True)
profiles = [('cas', 4, 16, 16), ('atomic', 4, 16, 16),
            ('atomic', 1, 16, 16), ('atomic', 4, 32, 32), ('atomic', 8, 32, 32)]
runs = []
for repeat in range(args.repeats):
    for protocol, workers, producers, capacity in profiles:
        env = dict(os.environ, BENCH_PROTOCOL=protocol, CRYSTAL_WORKERS=str(workers),
                   BENCH_PRODUCERS=str(producers), BENCH_CAPACITY=str(capacity), BENCH_JOBS=str(args.jobs))
        result = subprocess.run([sys.executable, str(root / 'scripts/run_integration.py'), '--probe', str(binary)],
                                env=env, cwd=root, text=True, capture_output=True, timeout=300)
        if result.returncode:
            print(result.stdout, file=sys.stderr)
            print(result.stderr, file=sys.stderr)
            raise SystemExit(result.returncode)
        records = [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
        record = records[-1]
        if record['accepted'] != args.jobs or record['confirmed_completed'] != args.jobs:
            raise SystemExit('load run did not conserve accepted identities')
        record['repeat'] = repeat + 1
        runs.append(record)
        print(f'{protocol} threads={workers} producers={producers} capacity={capacity}: '
              f'{record["settled_per_second"]:.1f}/s, p99={record["admission_p99_ms"]:.2f}ms', flush=True)
summaries = []
for protocol, workers, producers, capacity in profiles:
    group = [r for r in runs if (r['protocol'], int(r['workers']), r['producers'], r['capacity']) ==
             (protocol, workers, producers, capacity)]
    summaries.append(dict(protocol=protocol, workers=workers, producers=producers, capacity=capacity,
                          median_settled_per_second=statistics.median(r['settled_per_second'] for r in group),
                          median_admission_p99_ms=statistics.median(r['admission_p99_ms'] for r in group),
                          median_allocated_bytes_per_job=statistics.median(r['allocated_bytes_per_job'] for r in group)))
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(dict(jobs_per_run=args.jobs, repeats=args.repeats,
                                      summaries=summaries, runs=runs), indent=2) + '\n')
print(json.dumps(summaries, indent=2))
