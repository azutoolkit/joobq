# ADR 001 — Recoverable delivery and transition authority

Status: implementation contract; production cutover remains gated by integration, migration and fault evidence. This adopts the plan's single-primary/noeviction/intact-storage failure profile. It does not claim zero loss under asynchronous replica promotion or storage loss.

A producer supplies a stable request ID within one queue/namespace. Admission returns Accepted with the stable logical ID, Rejected for invalid or conflicting identity, or Unknown when Redis did not return a trustworthy reply. Unknown is resolved by looking up the same identity; resubmission must have identical payload bytes. Legacy add!/enqueue return jid compatibility remains separate until an explicit API migration.

One canonical, versioned record is authoritative for each identity. Updates compare the complete previous record and write its successor with a single HSET. Secondary ready/lease indexes are accelerators only. A failed update after the canonical mutation is an unknown outcome; repair must derive indexes from canonical state. Lua isolation is not rollback. No script may delete the canonical record in order to transition it.

States: Ready, Leased, Scheduled, Completed, Dead. Claims have a fresh token, owner ID, incremented attempt and Redis-time lease deadline. Only that current, unexpired token may settle or renew. Repeated identical settlement is idempotent, but an old token may never mutate a newer attempt. Lease expiry permits redelivery, not cancellation of the old fiber or its external effects. Business expiry is separate from lease expiry.

Use opaque payload strings, preserving Int64/decimal application data. Parse typed envelope fields in Crystal. Compare-and-set scripts inspect canonical ownership/version, not payload IDs or LREM matches. Wall-clock lease timestamps come from Redis TIME; local operation budgets use monotonic deadlines. Handle backwards server clock changes conservatively and expose the condition in monitoring.

Keep accepted/terminal records until an explicit retention policy is approved. This initial protocol has no automatic purge: removing receipts silently would invalidate idempotency. Deduplication retention, archive and safe tombstone compaction must be tested before high-volume production use.

Durability acknowledgements are a distinct transport policy. The initial reference lab requires appendonly=yes, appendfsync=always, noeviction, controlled ownership of the Redis namespace and intact storage. Admission must not claim replication/HA guarantees from Redis write success alone. A stronger failure model requires a separately reviewed durable journal/promotion design. Any future WAIT/WAITAOF barrier must use the same leased connection and cannot substitute for safe promotion.

Migration defaults to paused ingress, drained/fenced old workers, backup, resumable conversion, conservation/replay verification, then new workers and ingress. Legacy workers must not consume new records. After new admissions, recovery is forward reconciliation; restoring an older snapshot alone is not rollback.
