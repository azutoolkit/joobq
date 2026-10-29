# Queue, Worker and Scheduler allocation pass

This pass optimizes the existing list-based API. It does not route legacy jobs
through `JoobQ::Delivery` or change legacy queues into a leased delivery ledger.

## Implementation

- **Queue:** pre-size typed batch scratch storage, allocate the unreadable-member
  fallback only when needed, and use each input JSON size as an output buffer
  capacity hint. Typed deserialization and serialization still run, including
  encryption converters, defaults and validation. Hints are validated before
  writing and never truncate output. `Queue#jobs(page_number, page_size)` now
  forwards pagination to the store instead of always fetching the default page.
- **Worker:** keep one token array and a cursor instead of zipped pairs, a second
  token array, per-slice arrays and repeated deletion from the unspawned list.
  All claims enter shutdown tracking before spawning; argument capture is by
  value, and exceptions release tracking for the unspawned suffix. Keep the
  existing capacity and pacing, independent job fibers, middleware, latency
  metrics and lifecycle events. Completion parses a job ID only when debug
  logging actually requests it.
- **Scheduler:** stream routing and status changes with Crystal's standard JSON
  pull parser/builder. Avoid full `JSON::Any` object trees, preserve nested values
  and numeric spellings, validate the entire document, and use the final root
  queue value. Emit one root Enqueued status. Delayed promotion still writes the
  destination before removing the source in one Lua operation. Use EVALSHA with
  fallback only for a definite NOSCRIPT response; never retry an ambiguous write.
  The non-Redis Store fallback reuses the queue it already extracted.

No job objects, middleware continuations or user execution fibers are pooled:
their identity and per-execution state remain independent.

## Measurement method

`benchmarks/legacy.cr` has three separate modes: batch string admission through
Queue, execution and settlement through Worker, and delayed promotion through
Scheduler. These rates are **different operations**, not an end-to-end delivery
throughput result. The worker handler checks that each index executes once;
admission/promotion modes check every stored index and payload, plus promoted
status. Worker measurement waits for the processing list and local claim tracker
to drain.

Before and after release binaries use the same benchmark, 1 KiB application
payloads, four Crystal execution threads, four workers, a 128-job worker limit,
100-job admission pipelines, a 24-connection Redis pool, warning-level logs,
verified TLS and Redis AOF `always`. Logs, middleware and telemetry configuration
are identical. Input creation, fixture setup and post-run verification are outside
the timed/allocated region. Every repetition uses its own Redis fixture.
Three repetitions of 30,000 operations per mode/build run sequentially with
alternating before/after order (540,000 verified operations). No compilers or
other benchmark runs compete for CPU during measurement.

GC total bytes measure cumulative managed allocation, not live heap, peak RSS,
fiber stack memory or native Redis/TLS allocations. These are finite no-op tests,
not a production load or soak certification.

## Reproduce

Build a release binary from each source revision, then run each mode three times:

```sh
crystal build benchmarks/legacy.cr --release -o /tmp/joobq-legacy
CRYSTAL_WORKERS=4 BENCH_JOBS=30000 BENCH_MODE=queue \
  python3 scripts/run_integration.py --probe /tmp/joobq-legacy
CRYSTAL_WORKERS=4 BENCH_JOBS=30000 BENCH_MODE=worker \
  python3 scripts/run_integration.py --probe /tmp/joobq-legacy
CRYSTAL_WORKERS=4 BENCH_JOBS=30000 BENCH_MODE=scheduler \
  python3 scripts/run_integration.py --probe /tmp/joobq-legacy
```

The harness starts owned plain/TLS Redis servers and rejects runtime crashes or
nonzero exits. This benchmark uses only the TLS server.

## Local results (2026-10-29)

Crystal 1.22.1, Redis 8.0.2, five CPUs visible in affinity with a four-CPU cgroup
quota shared by the client and Redis. Median of three runs:

| Operation | Before bytes/job | After bytes/job | Allocation reduction | Before operations/s | After operations/s |
| --- | ---: | ---: | ---: | ---: | ---: |
| Queue | 7,917 | 5,332 | 32.6% | 65,239 | 68,402 |
| Worker | 12,174 | 8,164 | 32.9% | 12,258 | 12,282 |
| Scheduler | 10,333 | 6,674 | 35.4% | 13,541 | 13,964 |

Allocation reductions are repeatable; throughput samples are short and noisy.
The worker's unchanged pacing remains a throughput constraint. The result is
less allocation at similar observed throughput, not evidence of a new sustained
rate guarantee. See [all measurements and binary hashes](evidence/legacy-hotpath-2026-10-29.json).
Both binaries include the earlier uncommitted Delivery work; the comparison
isolates this legacy-path pass.

## Validation

The final modified core passed **567 examples**, and the paired local Pro
worktree passed **414 examples**, both with zero failures/errors/pending using
six configured workers and the owned Redis URL/TLS fixture. Ten new regression
cases cover full-document JSON validation, nested/escaped payloads, exact
numbers, duplicate routing/status keys, script-cache flush, destination failure,
queue filtering, pagination, serialization hints, unreadable batch members and
claim capture across multiple spawn slices. Existing encryption, shutdown,
retry, competing-scheduler and capacity checks also pass.

Formatting and whitespace checks pass. Changes are local and uncommitted;
hosted CI does not yet cover this revision. The paired Pro worktree required
no changes.
