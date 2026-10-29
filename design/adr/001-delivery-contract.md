# ADR 001 — Recoverable delivery and transition authority

Status: implementation contract; production cutover remains gated by integration, migration and fault evidence. This adopts the plan's single-primary/noeviction/intact-storage failure profile. It does not claim zero loss under asynchronous replica promotion or storage loss.

A producer supplies a stable request ID within one queue/namespace. Admission returns Accepted with the stable logical ID, Rejected for invalid or conflicting identity, or Unknown when Redis did not return a trustworthy reply. Unknown is resolved by looking up the same identity; resubmission must have identical payload bytes. Legacy add!/enqueue return jid compatibility remains separate until an explicit API migration.

One canonical, versioned record is authoritative for each identity. Updates either compare the complete previously read record (the compatibility CAS path), or read, validate ownership and write the successor within one atomic Lua invocation (the optimized path). Both use one authoritative HSET. Secondary ready/lease indexes are accelerators only. A failed update after the canonical mutation is an unknown outcome; repair must derive indexes from canonical state. Lua isolation is not rollback. No script may delete the canonical record in order to transition it.

States: Ready, Leased, Scheduled, Completed, Dead. Claims have a fresh token, owner ID, incremented attempt and Redis-time lease deadline. Only that current, unexpired token may settle or renew. Repeated identical settlement is idempotent, but an old token may never mutate a newer attempt. Lease expiry permits redelivery, not cancellation of the old fiber or its external effects. Business expiry is separate from lease expiry.

Use opaque payload strings, preserving Int64/decimal application data. Validate the full typed envelope and checksum in Crystal before execution. Atomic scripts may decode envelope metadata only when every numeric field is an exact integer in their explicitly bounded encoding range; application payload remains an opaque string. Records outside that range use the Crystal Int64 CAS path without mutation by the optimized script. Compare-and-set scripts inspect canonical ownership/version, not payload IDs or LREM matches. Wall-clock lease timestamps come from Redis TIME; local operation budgets use monotonic deadlines. Handle backwards server clock changes conservatively and expose the condition in monitoring.

Keep accepted/terminal records until an explicit retention policy is approved. This initial protocol has no automatic purge: removing receipts silently would invalidate idempotency. Deduplication retention, archive and safe tombstone compaction must be tested before high-volume production use.

Durability acknowledgements are a distinct transport policy. The initial reference lab requires appendonly=yes, appendfsync=always, noeviction, controlled ownership of the Redis namespace and intact storage. Admission must not claim replication/HA guarantees from Redis write success alone. A stronger failure model requires a separately reviewed durable journal/promotion design. Any future WAIT/WAITAOF barrier must use the same leased connection and cannot substitute for safe promotion.

Migration defaults to paused ingress, drained/fenced old workers, backup, resumable conversion, conservation/replay verification, then new workers and ingress. Legacy workers must not consume new records. After new admissions, recovery is forward reconciliation; restoring an older snapshot alone is not rollback.

## Hot-path amendment (2026-10-29)

Atomic admission, claim and transition scripts eliminate client read/CAS races and
extra round trips. Redis TIME, token/owner/attempt checks and canonical-before-index
write ordering remain inside each script. Ready scans are limited to 100 candidates.
Cached EVALSHA calls fall back to EVAL only on a confirmed NOSCRIPT response, never
on connection loss, timeout or an arbitrary script error.

The bundled Redis cjson encoder uses 14 significant digits. Atomic paths explicitly
set that precision and reject non-integral, negative or >=99,999,999,999,999 metadata
values to the existing CAS path. This preserves large Int64 attempt metadata instead
of rounding it. Payload JSON is never parsed by Lua: its large integers and decimal
spelling remain bytes in a string.

A claim returns the original envelope for checksum verification before user code.
If that verification fails, a token/owner/attempt-guarded cleanup restores and
quarantines the original corrupt bytes; it cannot overwrite a successor's claim.
Settlements compare the validated claim's payload/digest as well as ownership.
Index failures after HSET still produce Unknown and are reconciled from authority.

One runtime scanner schedules renewal only for leases which reach renewal time.
Per-lease fiber mutexes serialize renewal and settlement; short jobs allocate no
renewal fiber or rendezvous channels. Renewal concurrency is bounded by active
execution capacity, and a slot is retained until its operation finishes.
