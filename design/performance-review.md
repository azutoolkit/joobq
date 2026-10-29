# Core and Pro performance review — 2026-10-29

Reviewed core PR #20 and Pro PR #16 together, including the earlier uncommitted
Delivery and legacy hot-path work. Complete Pro changes, measurement tables and
raw evidence live in the companion repository at
`joobq-pro/design/performance-review.md` and
`joobq-pro/design/evidence/performance-review-2026-10-29.json`.

## Core changes

- [RedisClient](../src/joobq/redis_client.cr): failed MULTI blocks and failed EXEC
  reply parsing now abort the connection. The baseline returned OK to a subsequent
  PING after an application abort and raised TypeCastError from an unread integer
  after an EXEC element failed. Do not drain by issuing extra mutations, flush an
  aborted buffer or retry an unknown transaction. Successful transaction semantics
  remain unchanged; Redis may execute other EXEC elements when one fails.
- [Delivery journal](../src/joobq/delivery/journal.cr): reuse cached Script wrappers,
  private key arrays and capacity text; use expected JSON size as a serialization
  capacity hint; reuse the checksum encoder. Writes still perform exact-byte CAS,
  retain capacity/byte limits and preserve corrupt source bytes during quarantine.
  Cached scripts retry only explicit NOSCRIPT, never a lost reply.
- Stress fixtures and benchmarks now select the right scheduler API for modern
  Crystal execution contexts versus deprecated `-Dpreview_mt`.

The 100 KiB journal-update benchmark reduced managed allocation by **29.6%**
(522,512 to 367,989 bytes per operation). It includes preparation of expected
JSON for the next CAS. Redis command count remains three including Lua's internal
commands; EVALSHA reduces script transfer, not the number of mutations. These
are component measurements with owned verified-TLS Redis/AOF-always fixtures,
not a durable completed-jobs throughput claim.

Pro adds one-buffer canonical JSON, admission-receipt reuse and monotonic
terminal batch projections, a synchronized metrics registry, periodic depth
sampling and pipelined counter reads. Shared mutable lease/context/document
classes keep reference identity; existing transient records are already structs.

## Safety boundaries

The current proof is at-least-once delivery with idempotent request identities
and fenced settlement under the tested single-primary persistence contract.
It is not unconditional zero data loss across disk loss, stale replica promotion,
arbitrary ACL/OOM failures or Redis Cluster. Pro workflow append still performs
multiple authoritative writes; Lua isolation is not rollback. External effects
and callbacks need idempotency. Long user handlers require cooperative yielding,
and retained receipts/outboxes still need a safe compaction/archival design.

Use the hardened RedisStore/RedisPool for deadline/no-replay behavior. Do not
drop persistence, checksum checks, source retention or lease ownership to obtain
higher synthetic throughput. Remaining pool scans/lock contention and full
terminal-document parsing should be profiled under real workloads before
replacing their algorithms.

See [legacy allocation evidence](legacy-hotpath-optimization.md),
[Delivery allocation evidence](delivery-allocation-optimization.md), and the
[production risk report](production-v1-audit.md) for previous work and outstanding
operational acceptance gates.

## Validation

Modern execution-context suites passed **573 core and 420 paired Pro examples**
with six configured workers, zero failures/errors/pending and owned Redis URL/TLS
fixtures. Redis SIGKILL/AOF tests retained 990 queued + 10 claimed payloads and
100 canonical records, recovering 20 expired leases. Batch process-fault checks
conserved 20/20 completions after SIGKILL and 8/8 after bounded SIGTERM.

Deprecated preview_mt was also exercised. An execution-order characterization
spec incorrectly assumed serial job execution despite concurrent batching; it
now explicitly uses one active slot and passes. Pro initially saw three
connection-loss errors during concurrent stress; its isolated full rerun passed
420 examples. Their root cause is unproven, so legacy saturation support is not
certified. Use modern execution contexts on Crystal 1.22.

Both transaction failures were reproduced before the fix and pass afterwards.
Formatting and whitespace checks pass. The source and evidence are included in this branch; hosted CI must validate
the pushed commit. Detailed validation records, including
initial failures, are in the companion Pro report.
