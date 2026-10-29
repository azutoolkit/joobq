# Delivery ledger prototype

`JoobQ::Delivery::Ledger` implements the storage contract in [ADR 001](adr/001-delivery-contract.md). It is experimental: existing `Queue`, `Worker`, producer helpers and Pro workflows still use the legacy protocol. Constructing a ledger does not upgrade a queue or make its workers lease-aware. Do not point legacy workers at the new keys.

```crystal
store = JoobQ::RedisStore.new(url: ENV.fetch("REDIS_URL"))
ledger = JoobQ::Delivery::Ledger.new(store.redis, "tenant_a", "invoices")
result = ledger.admit("invoice-123:send:v1", %({"invoice_id":123}))
case result.code
when .accepted?
  # The identity has an authoritative record (possibly already terminal).
when .rejected?
  # Payload is empty/oversized or this identity already has different bytes.
when .unknown?
  # Resolve this SAME request ID. Never invent a new ID for an ambiguous write.
  record = ledger.resolve("invoice-123:send:v1")
end

if claim = ledger.claim("worker-unique-instance-id", lease: 30.seconds)
  # Execute an idempotent effect here. Renew while running; handle Stale/Unknown.
  outcome = ledger.settle(claim)
end
```

Admission stores opaque payload bytes and a versioned typed envelope in an authoritative Redis hash. This preserves large integers without a Lua JSON decode/re-encode. Compare-and-set transitions update the canonical envelope first; ready/lease sorted sets are repairable indexes. A Lua error after the authoritative write does not roll it back. Resolve the receipt and run repair; never interpret an error as proof the write did not occur.

Claims carry a fresh token, owner, attempt and Redis-time lease deadline. Renewal and settlement compare the complete previous envelope and check the old deadline inside the atomic Lua operation. Expired/stale claims cannot change a newer attempt. Repeating settlement for the same token and destination returns `AlreadyApplied`; the first applied delay wins. Claims whose responses are lost remain leased and become recoverable on expiry. Lease loss cannot cancel an already running external effect.

Call `repair(cursor)` repeatedly until it returns `"0"`, and repeat complete passes continuously. It reconstructs indexes and releases expired claims using the observed canonical envelope as a compare-and-set guard. HSCAN `count` is a work hint, not a strict memory bound. Wrong-type keys or missing Redis privileges require operator repair; they are not silently deleted. Corrupt envelopes fail closed with `CorruptRecord`.

Limits: 1 MiB default payload, 1–1024 byte request ID, safe namespace/queue names, 1 ms–24 h leases. No automatic receipt retention or terminal deletion exists yet. Long-lived production workloads need bounded archival/tombstones before adoption. Redis Cluster, clock rollback handling, a global worker resource budget, automated reconciliation supervision, admission backlog limits and production cutover are not implemented here.

The reference fault profile is one Redis primary, `maxmemory-policy noeviction`, AOF with `appendfsync always`, and intact storage. The tests prove specific contention, deadline, partial-index and process-restart cases. They do not establish zero loss under disk loss, asynchronous failover, or exactly-once business effects. See the remaining P04–P16 gates in [the implementation plan](enterprise-v1-plan.md).
