# Leased runtime and operations guide

This is a review candidate, not a certified enterprise v1 release. Read the
[measured results and remaining gates](implementation-validation.md). Legacy
`JoobQ.add`, `Job.enqueue`, queues and schedulers do not automatically use this
runtime. Do not mix transport protocols on the same application queue.

## Register, admit and execute

```crystal
require "joobq"

store = JoobQ::RedisStore.new(url: ENV.fetch("REDIS_URL"),
  ca_file: ENV.fetch("REDIS_CA_FILE"), pool_size: 24,
  operation_timeout: 2.seconds)
runtime = JoobQ::Delivery::Runtime.new(store, "orders", capacity: 16,
  lease: 30.seconds, execution_timeout: 5.minutes, max_records: 100_000)
ledger = runtime.register("payments") do |payload, context|
  context.check!
  # Call your service with context.idempotency_key. Check cancellation before
  # each effect; cancellation cannot interrupt an arbitrary blocking function.
  JoobQ::Delivery::Outcome.new
end
receipt = runtime.admit("payments", "order-123-charge", %({"order":123}))
case receipt.code
when .accepted?
  # The Redis primary confirmed admission. Keep the stable request ID.
when .rejected?
  # Fix the reported conflict/capacity issue before admitting new work.
when .unknown?
  # Resolve using ledger.resolve("order-123-charge"), or repeat admission with
  # the SAME request ID and bytes. Never silently invent another identity.
end
runtime.serve(15.seconds) # SIGTERM/SIGINT -> stop ingress/claiming and drain
store.close
```

`register("payments", PaymentJob)` deserializes a `JoobQ::Job`, observes expiry,
uses `claim.attempt` for retry accounting and invokes `perform_with_context`
when provided, otherwise `perform`. A failed typed job retries at exponential
intervals until `max_retries` is exhausted. Custom handlers return
`Outcome.retry(5.seconds)` for a deferred attempt or `Outcome.new(State::Dead)`
for a permanent failure. Legacy retry/rate/uniqueness middleware is not invoked.

Capacity is the number of actual execution fibers shared by the queues in one
runtime. Each runtime has its own budget; aggregate process and deployment
budgets are the operator's responsibility. A timed-out handler retains its slot
until its real fiber exits. The default five-minute execution deadline and lease
loss cancel its context and stop renewal; they do not kill Crystal fibers or
undo external effects. Another process may redeliver after expiry. External
side effects require stable idempotency keys or transactional application logic.
An already in-flight settlement at shutdown can finish if its token still owns
the lease; it cannot settle a successor's claim. An incomplete `Drain` must be
reported as an unclean shutdown. Construct a new runtime after stopping one.

## Redis, capacity and secrets

Production initialization checks `appendonly yes`, `appendfsync always` and
`maxmemory-policy noeviction`. The ACL must permit the configuration read as
well as the runtime's data commands and Lua scripts. `production: false`
explicitly disables that startup check for non-production use. These checks do
not establish replica durability, disk-loss protection, failover consistency or
multi-region availability. Cluster/Sentinel/pooler topologies remain uncertified.

The total Redis operation deadline includes pool checkout, DNS/connect, TLS,
authentication, database selection and command I/O. A lost mutation response is
an unknown outcome, not permission for automatic replay. TLS uses peer/hostname
verification; configure a trusted CA. Use separate scoped Redis principals for
application and administration. Rotate by provisioning a replacement principal,
starting new store/runtime instances, draining the old instances, then revoking
the old principal. Do not mutate credentials in a live shared connection pool.
This rollout procedure still requires deployment-specific validation.

Each queue retains at most `max_records` canonical records, including completed
and dead receipts. Journals retain at most 100,000 documents, each at most 2 MiB.
At capacity, new admissions fail closed; repeats of existing identities remain
resolvable. There is **no automatic retention/archival compactor**. Do not delete
receipts to free space without a reviewed replay-retention policy: this removes
deduplication evidence. Sustained production throughput and long soaks are gated
on a safe retention design and sufficient storage. Redis eviction is forbidden.

## Telemetry and management

Pass `telemetry: JoobQ::Delivery::Telemetry.new(exporter, capacity: 512,
sample_every: 10)` to the runtime. `OTLPExporter.new(https_endpoint)` emits
OTLP/HTTP JSON producer and consumer spans with W3C trace context. HTTP requires
explicit `allow_http: true` for local collectors. Export runs in a separate
bounded fiber; failures and drops are counted, not allowed to stall jobs.
`runtime.prometheus` exposes admissions, settlements, execution count/time,
active/capacity, telemetry failures/drops, pending/leased and quarantine counts.
Pending includes future scheduled records. Job IDs are not metric labels.
Histograms, collector authentication, deployment alerts and an authenticated
runtime-specific HTTP metrics endpoint are not supplied by this change. Mount
this output behind your application's authenticated monitoring endpoint.

The existing management server now binds loopback by default and requires
`JOOBQ_API_READER_TOKEN`, `JOOBQ_API_OPERATOR_TOKEN` and/or
`JOOBQ_API_ADMIN_TOKEN` (minimum 32 bytes each). GET/HEAD require Reader; writes
require Operator; DELETE and reset/config paths require Admin. Bearer tokens
are compared by digest, bodies are bounded to 1 MiB, and socket operations have
five-second timeouts. Use a trusted TLS reverse proxy for remote access. Audit
logs contain role/method/path/ID, never tokens or bodies. The existing routes
still manage **legacy queues**, not this runtime's namespace. For overlapping
management token rotation, construct `ManagementPolicy` with both old and new
tokens, roll out, then remove the old token. `unsafe_no_auth` is a handler-only
test escape hatch and must not be used in a deployment.

## Migration and restore

1. Stop all legacy producers, workers and delayed schedulers; wait for active
   work or account for redelivery. Take an infrastructure backup of Redis.
2. Construct a ledger with the target namespace/queue and a `Migration` using
   the same store and a stable operator owner ID. Call `run(quiescent: true)`.
   It gates target claims, inventories ready/processing/delayed/DLQ records,
   preserves original bytes and imports stable `legacy:<jid>` identities.
3. Review `logical_records`, `source_entries`, and digest. Conflicting copies or
   changing source data abort and leave the gate in place. Correct the source
   deliberately and rerun with the same owner. No automatic destructive rollback.
4. Keep writers stopped and export `Backup.new(redis, namespace).export(io,
   quiescent: true)` to a protected file. Backups contain application payloads;
   encrypt them with your backup system and restrict access. The implementation
   holds the inventory/image in memory: size the maintenance host accordingly.
5. Restore the image to a separate compatible Redis using `restore(io)`, which
   checks namespace, digests and divergent keys before writing. An interrupted
   matching restore resumes. Only persistent namespace keys are supported;
   expiring keys are rejected. Verify logical receipts and run the application
   against the restored copy. Keep the original store available for rollback.
6. Call `activate(report)` on the original migrator only after verification.
   Start leased consumers and switch producers explicitly to `runtime.admit`.
   Original legacy keys remain for operator-controlled archival. Do not restart
   legacy consumers against them. Restoring does not automatically activate a
   captured maintenance gate; preserve the owner/report and verify before release.

Namespace backups do not include legacy workflow history or external systems.
Workflow deployments need a coordinated full-store and application-data backup,
including bridge markers and Pro history. Measured RPO/RTO, replica promotion,
secret rotation and disaster recovery remain deployment acceptance work.
