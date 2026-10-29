# Production v1 audit: JoobQ core and JoobQ Pro

Audit date: 2026-10-29. Baselines: core `b38961d` (declares 0.4.2), Pro `5f68249` (declares 0.2.0). Both were current `origin/master` when fetched. Local hardening branches: `codex/v1-reliability-audit` in each repository. This is a code-and-local-test assessment, not certification of an application deployment.

**Decision: NOT ready for an enterprise v1 release.** There are reproducible loss/partial-commit paths, missing distributed ownership in the core, and incomplete Pro features. The patches accompanying this report mitigate specific failures; the unchecked release gates below remain mandatory. Neither “zero data loss” nor sustained 35,000 completed jobs/second has been established.

## 1. Architecture and delivery contract

Core producers serialize job objects into Redis lists. Workers pipeline `RPOPLPUSH` into a shared `joobq:processing:<queue>` list, execute middleware and job code, then remove payloads with `LREM`. Retries use a sorted set; DLQ storage uses a sorted set plus count hashes. Shutdown tracks claims in a **process-local** `InFlight` registry. The pool dependency is wrapped with a mutex/channel fix for Crystal's parallel execution context.

Pro workflows are a second state machine: Redis event histories and metadata, sequence-checked Lua appends, leased ready/timer/deadline sets, an orchestrator and reconciler, and ordinary core jobs as activity transport. Pro correctly treats transport as potentially duplicated/lost. Workflow sequence checks protect history transitions; they cannot roll back an activity's external side effects. The reviewed history store is Redis, not PostgreSQL. Archive adapters are a separate concern.

A defensible v1 contract is **at-least-once delivery under a documented Redis durability/failure model**, with idempotent external operations. Define an accepted enqueue as a successful durable admission response, and distinguish an unknown response from a rejected request. Exactly-once external effects require an application idempotency key, transactional outbox/inbox or equivalent coordination with the external system. A Redis lease alone cannot guarantee that a charge, email or database update happens once.

Redis isolation is not rollback. `MULTI`/pipelines and Lua scripts can partially apply writes when later commands fail. Redis asynchronous replication can lose acknowledged writes during failover. AOF `everysec` also has a loss window. `appendfsync=always` improves a single server's acknowledged-write durability but does not prove safety under storage failure, asynchronous failover or eviction.

## 2. Top three adoption blockers

| Priority | Blocker and evidence on original code | Mitigation in this branch | Still required |
| --- | --- | --- | --- |
| P0 | **Non-durable handoffs / partial commits.** `RedisStore#process_due_delayed_jobs` pipelined ZREM before RPUSH; a wrong-type destination lost the member. `#move_to_dead_letter` removed processing before writing DLQ. `Scheduler#enqueue_due_jobs` destructively fetched before application-side enqueue. Pro `workflows/lua/append.lua` advanced history/sequence before dispatch; a bad dispatch key left a scheduled event without its effect. All four paths are source-confirmed; three have direct failing/passing regressions, with the scheduler routed through the same new promotion primitive. | Redis delayed promotion checks source membership and writes destination before removing source, in one Lua call per member. Both schedulers use it. DLQ storage precedes processing removal. Worker exception paths retain processing when settlement raises. Pro checks authoritative key types before any history write. | Fenced, idempotent settlement and admission; recovery for every partial/unknown outcome; malformed-member quarantine; fairness beyond the first 50 due entries. Pro preflight is not rollback for arbitrary ACL/OOM/runtime failures. |
| P0 | **No distributed ownership of core processing claims.** `claim_jobs_batch` ignores worker_id; payloads share a list; `Queue#start` calls `reprocess_busy_jobs!`, which moves only one arbitrary processing item, including a live peer's. Cleanup uses raw payload/ID and often removes all matching copies. SIGKILL leaves the rest stranded until another recovery/expiry action. | Existing signal/shutdown safeguards retained. Failed settlement now keeps a recoverable source. | Claim IDs, owner/session tokens, visibility deadlines, heartbeats and compare-token settlement; continuous lease reaping; stale-worker rejection. Rolling startup must not steal live work. Redelivery requires idempotent side effects. |
| P1 | **Unbounded work and insufficient outage boundaries.** The polling loop spawned another batch every iteration regardless of prior work; nested spawn escaped the caller's containment. With batch size 2 and 20 blocked jobs, the original claimed all 20. RedisStore supplied a pool wait timeout but no DNS/connect/socket timeouts. | Atomic per-worker in-progress budget, claimed before spawning and released after handling; nested spawn removed. DNS/connect and command I/O timeouts are now configurable (default 5 seconds). | Process-wide budgets across worker replacement/resizing, explicit execution deadlines/cooperative cancellation, jittered outage backoff/circuit state, end-to-end checkout budget, saturation metrics and sustained load/soak evidence. |

P0 here means a release blocker involving recoverability or ownership; this is not a claim of a published security severity.

## 3. Detailed findings by enterprise pillar

### Reliability and shutdown

Positive foundations: `lifecycle.cr` intercepts termination, stops ingress/schedulers/queues, drains tracked jobs, requeues at the deadline, flushes latency and reports abandoned work via exit status. `InFlight` tracks jobs before spawning and guards late retry/DLQ handling. Pro has orderly teardown, scheduler lease resignation and rollback on failed start. Existing subprocess shutdown tests are useful and should remain.

Remaining gaps:

- `InFlight` tokens do not cross processes or accompany Redis acknowledgements. `finished` happens before cleanup, so shutdown can consider a job drained before Redis acknowledgement finishes. Requeue steps can outlive their local timeout; the deadline limits the waiting caller, not the operation itself. Never describe this as cancellation.
- Shutdown requeues work that may still be executing external effects. The code documents this honestly. Require application-level idempotency and a termination grace period that covers the bounded drain/requeue/flush budget. On Redis failure, surface recovery failure rather than interpreting an abandonment count as confirmed requeue.
- Public `Queue#add_batch` and several enqueue/error helpers log and swallow failures. Producers cannot reliably distinguish acceptance, rejection and partial admission. Preserve evidence of unknown outcomes and provide a durable request ID; do not blindly retry a whole partially accepted batch.
- `fetch_due_jobs(remove: true)` remains a destructive public primitive. Built-in Redis schedulers no longer use it; custom callers still need migration to a durable handoff API.
- Malformed due jobs now remain stored instead of being silently deleted. They, or entries for unavailable queues, can obstruct progress through the first limited page. Add a retained quarantine and per-queue due indexes or fair cursoring.
- Processing recovery needs a bounded reaper based on claim leases, **not** business `expires`. `ExpiredJobReaper` scans list prefixes, can touch live executions and cannot distinguish ownership. Expiry/DLQ policy is not crash recovery.

### Redis, connection pooling and security

The existing `redis_pool_safety.cr` addresses real thread races in pool 0.2.4 and returns capacity after failed connection creation. Preserve its stress tests. It monkey-patches a dependency and must be covered by pinned compatibility tests; do not silently upgrade that pool without review.

The new RedisStore options are `connect_timeout:` and `command_timeout:` (`Time::Span`), with environment overrides `REDIS_CONNECT_TIMEOUT` and `REDIS_COMMAND_TIMEOUT` in seconds. Positive values are required. DNS uses the connect timeout; socket reads/writes use the command timeout. These are **per-operation limits**, not a total request/checkout deadline. The Redis 2.9.1 wrapper reports the tested socket timeout as `Redis::ConnectionLostError` and may retry a single command once through `with_reconnect`. An execution followed by a lost reply can therefore duplicate a non-idempotent write. Classify outcomes and make mutating commands idempotent before adding more retries.

The store still lacks exposed verified-TLS/ACL username options, cluster routing and a tested Sentinel failover contract. Pro scripts touch dynamically constructed keys and global indexes across queues: current schemas/scripts are not Redis Cluster hash-slot-safe. A single Redis primary is a supported architectural assumption to document, not a hidden HA guarantee. Test server certificate validation and credentials rotation before claiming TLS/ACL production support.

The default pool capacity is 500 **per process**. Budget aggregate connections, buffers, Redis maxclients, memory and OS descriptors from workload evidence. `Pool#checkout` can spend time connecting and then waiting; its wait timeout is not a complete checkout deadline.

The REST server defaults to `0.0.0.0:8080` and constructs `APIHandler` without an authentication handler. Treat its management routes as privileged. Ship a loopback/private default or explicit authenticated mounting, authorization for mutation/inspection, request limits and an audit trail. Until then require a protected network/proxy; don't expose it directly.

`RedisStore#reset` uses FLUSHDB. Test harnesses must use dedicated Redis instances. Production reset/purge interfaces need explicit safeguards and namespace-scoped deletion. Payload encryption support exists; error contexts, workflow histories, archives and arbitrary exception messages still require a data-classification/redaction policy.

### Crystal concurrency and throughput

`worker_batch_size` now also caps claimed/executing work **per worker object**. Approximate steady-state queue capacity is workers × batch size. Existing executions can temporarily overlap replacement/resized workers; Pro timeout helpers can leave child fibers running. This is not yet a global process cap.

The worker's fixed 10 ms inter-batch delay, 100 ms idle delay, whole-list scans in `remove_job_from_processing_by_id`, O(N) LREM, repeated JSON decode/encode, per-job INFO logs and multiple Redis stats commands all need measurement. The generic `RedisPipeline#batch_operations` and read helper ignore their pipeline argument and call closures independently: those APIs do not establish batching and can consume another pooled connection while one is held. Pipeline stats are unsynchronized and compute an average from the previous call count (initially zero).

Do not optimize away durability to hit a headline rate. At 35,000 jobs/sec and 200 ms average execution time, Little's law requires roughly 7,000 concurrent executions, before overhead. Establish latency, memory, connection and backpressure budgets before choosing that concurrency. The README's 35k and comparison numbers lack a reproducible end-to-end, durable-workload artifact in this audit. The restart probe's enqueue timing is not a worker throughput benchmark.

Core RPUSH/RPOP behavior is LIFO; do not describe it as FIFO or silently change it in a compatibility patch. Specify ordering, fairness and starvation requirements for v1.

### Pro feature maturity and history integrity

- **Batches:** `Batch.current_batch` is a class variable despite a “thread-local” comment. `BatchJob#batch_id` returns nil; documented automatic association is incomplete. Completion loads and rewrites a JSON object, accepts but does not deduplicate jid, and enqueues callbacks outside atomic state advancement. Concurrent completions can lose updates or duplicate callbacks. Implement persisted membership, atomic per-job terminal accounting and a callback outbox, or exclude batches from the supported v1 scope.
- **Unique jobs:** default argument hashing includes runtime metadata (such as random jid); it is not a stable user-argument identity. SET-NX lock and enqueue are separate operations; failure can leave a lock without a job. Release is unconditional DEL, so an old execution can delete a newer owner's lock after expiry/reacquisition. Store an execution token, compare-and-delete, and atomically admit the job with its lock. Test all three modes and retries.
- **Rate limiting:** `allow?` checks before execution and `increment` runs after success. Many fibers can all pass before any increments; failed external attempts are not counted. Use one Redis-time Lua admission operation for window pruning, capacity check and token insertion. Make policy explicit about rejected attempts, retries and cancellation; do not consume job retry budget for normal backpressure.
- **Workflow activities:** `ActivityRunner` correctly guards stale attempts and separates execution errors from recording errors. But steps default to nil execution/heartbeat deadlines. A lost completion after StepStarted can remain Running indefinitely without a configured deadline. Require a bounded activity recovery policy or a durable completion outbox; make timeout defaults and compensations explicit.
- **History:** type preflight fixes the demonstrated WRONGTYPE partial append. An ACL denial or resource/runtime failure after the first write still needs reconciliation. Persist authoritative intent before dispatch and reconstruct missing timers/deadlines/indexes; assert history sequence and metadata agree. Announcements use best-effort pcall, so observers are not an audit ledger and the README's “if and only if” event-delivery wording is too strong.
- **Store injection:** core `config.store` and `RedisStore.instance` are distinct. Pro Store defaults, metrics, unique locks, rate limiting and batches often choose the singleton; activity queues use core configuration, while workflow Runtime is a process-global store. A custom workflow store can write activity jobs to Redis A while workers read Redis B. Unify a runtime dependency object and reject mixed-store workers; add a two-server integration gate.

### Observability and logging

Useful existing components: core EventSink/EventBus, bounded best-effort event buffering and dropped counter, mergeable latency histogram, worker registry/queue stats; Pro metrics collection, percentiles, alerts and JSON management endpoints. An EventSink is an integration hook, not proof of an implemented OpenTelemetry exporter. No native Prometheus exposition or OTel SDK integration was found in the reviewed src trees (the license feature name alone is not implementation).

This branch adds opt-in core `JSONLogFormatter` and preserves `entry.data` and `entry.context` in Pro's WebSocket formatter. Configure stdout logging as:

```crystal
require "joobq"
Log.setup(:info, Log::IOBackend.new(STDOUT, formatter: JoobQ::JSONLogFormatter))
```

Structured job/worker/queue identifiers live under `data`; correlation metadata under `context`. Numeric fields retain their types. This does not redact arbitrary user messages. Pro WebSocket dispatch still needs bounded buffering, reconnect/backoff and loss metrics so a disconnected dashboard cannot compromise logging.

Before release add low-cardinality Prometheus counters/gauges/histograms for accepted/completed/retried/quarantined work, oldest queue age, live claims, admission capacity, Redis wait and command latency, unknown outcomes, heartbeat lag, dropped telemetry, recovery failures and active loops. Keep job IDs in logs/traces, not metric labels. Distinguish queue wait from `perform` duration and from settlement duration; current success-log `processing_time` includes wait. Use monotonic time for elapsed measurements.

Pro's shared `metrics_by_queue` Hash is written during middleware matching and read by collectors without a common lock. Atomic individual counters do not protect the Hash. Worker-count metadata can become stale after resize; per-process Redis snapshots have no expiry. Define snapshot TTL/heartbeat and cross-process aggregation semantics; don't sum global totals repeated in every process snapshot.

### Type safety and testing

Use typed claim, settlement and transport-result records instead of Bool/string success inferred from logging. At external boundaries validate job envelopes, workflow event versions, JSON kinds, numeric ranges and Redis response shapes. The numerous `not_nil!` in workflow state/decider code are often justified by validated event/definition invariants; replacing them mechanically would hide corruption. Validate those invariants at ingest/replay and return actionable typed failures/quarantine for corrupt histories.

Existing suites already cover pool contention, signals/drain deadlines, retries, queues, encryption, workflow sequence conflicts, duplicate delivery, stale attempts, timers, shutdown and DEBUG RELOAD. Core CI runs 1/4 workers; Pro CI also has a 1/4 matrix. Pro's existing CI Redis has persistence disabled, and DEBUG RELOAD is not a power-loss/failover test. Some integration specs skip if Redis is absent; release CI must reject unexpected skips. The new append regression fails explicitly if Redis is unavailable.

## 4. Prioritized v1.0.0 action plan

1. **P0 — Define and freeze the delivery/API contract (maintainers + platform).** Document accepted/rejected/unknown enqueue outcomes, at-least-once semantics, supported Redis topology and RPO/RTO. Pin core/Pro/shard/compiler versions; Pro currently follows core master. Gate: a published compatibility matrix and executable contract tests.
2. **P0 — Replace shared-list recovery with leased claims (core owner).** Introduce a versioned envelope with job ID, attempt, unique claim token, owner epoch and lease deadline. Atomically reserve/renew/settle; acknowledgements compare the token. Reaper recovers expired leases only; startup never moves peers' live claims. Gate: multi-process rolling deploy, SIGKILL, lost-claim-response and stale-ack tests with no unrecoverable accepted IDs.
3. **P0 — Make admission and settlement replay-safe (core + workflow owners).** Stable producer request IDs; atomic source/destination transitions; retained unknown outcomes; durable workflow effect intent and repairs. Producer exceptions propagate. Define malformed quarantine and fairness. Gate: inject failure before/after every write and drop replies; each accepted ID is queued, leased, terminal or explicitly quarantined.
4. **P0 — Complete Pro features or narrow support (Pro owner).** Fix batch identity/accounting/outbox, unique token ownership, atomic rate admission, shared runtime store and missing activity deadlines. Gate: documented batch/uniqueness/rate examples execute correctly under concurrent processes and restarts. Unsupported features must not be advertised as enterprise guarantees.
5. **P1 — Bound resource use and failure recovery (runtime owner).** Promote the per-worker bound to process/queue budgets that survive resize/restart; use bounded channels and supervised loops. Configure end-to-end Redis deadlines, jitter/backoff and explicit half-open probes without blindly replaying writes. Gate: stalled Redis/slow external services keep memory, fiber count, connections and shutdown time within budgets; loops recover after outages longer than current restart limits.
6. **P1 — Secure deployment and recovery (platform/security).** Verified Redis TLS + ACLs, authenticated management API, payload/log policy, noeviction dedicated Redis, persistence/replication contract, encrypted off-host backups and tested restores. Define Redis Cluster as unsupported until the key/script design changes. Gate: failover, key rotation, backup restore and recovery-runbook exercises on the intended topology.
7. **P1 — Ship operational telemetry (observability owner).** Protect shared registries, expire snapshots, add Prometheus/OTel adapters, structured stdout, tracing/idempotency context and dropped-telemetry alerts. Gate: saturation, unknown outcomes, stuck claims and stale workers are visible during a fault drill; a failing telemetry sink does not block jobs.
8. **P1 — Establish performance evidence (performance owner).** Release builds, documented hardware/network, actual job payload distributions, fixed Redis persistence and instrumentation, open-loop offered load, successful settlement counts, per-stage p50/p95/p99, max RSS/fibers/connections and backlog. Gate: agreed ≥35k completed jobs/sec sustained for 30 minutes, then a multi-hour soak, with bounded backlog and agreed latency; repeat with injected failures at realistic traffic. Do not substitute batched enqueue throughput.
9. **P1 — Gate release on hosted CI and review (release owner).** Run locked dependency tests on Crystal 1.22.x, 1/4 workers, supported Redis versions, forked processes and persistence profiles. Add randomized state-machine/JSON tests and deterministic fault injection. Publish reviewed evidence, release notes and key-schema upgrade/rollback procedure; only then set version 1.0.0 and tag.

## 5. Patch inventory and validation

Implemented code, not pseudocode:

- `src/joobq/worker.cr`: bounded in-progress accounting, one job fiber, recoverable failed settlement.
- `src/joobq/redis_store.cr`: destination-first guarded delayed promotion, DLQ ordering, explicit DNS/connect/command limits.
- `src/joobq/scheduler.cr`: uses guarded Redis promotion instead of destructive fetch/enqueue.
- `src/joobq/json_log_formatter.cr`: opt-in structured JSON formatter.
- Pro `src/workflows/lua/append.lua`: preflight authoritative key types and parent wake counter; Store comments clarify the real guarantee.
- Pro `src/log/backend.cr`: retains structured metadata.
- Regression specs in both repositories; `scripts/redis_restart_smoke.py` and its Crystal fixture create and destroy their own Redis, SIGKILL it and verify acknowledged payloads after AOF restart.
- Core CI pins its service to Redis 7.4, uses frozen shard installation and runs the isolated crash probe after specs. Hosted execution is still required.

See `validation.md` beside this report for exact runs/results and limitations. Local services used separate ports and data directories; shared workspace Redis/PostgreSQL were not reset. Pro validation links the patched core worktree, not a separately released core tag. A production version bump is intentionally not part of an audit with open blockers.
