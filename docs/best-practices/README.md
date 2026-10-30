---
description: Make repeated work safe, failures visible, and recovery routine.
---

# Best Practices

Reliable background processing is a contract between your application, workers, Redis, and downstream systems. Start with these habits:

1. Pass identifiers rather than entire records or secrets.
2. Make repeated execution safe with a business-level idempotency key.
3. Bound external calls and classify failures before retrying.
4. Separate queue plumbing from business services.
5. Test termination, Redis outages, ambiguous acknowledgments, and restore procedures.
6. Measure completed useful work, not only enqueue speed.

Follow the focused guides:

- [Idempotent jobs](idempotency.md): protect business effects across retries.
- [Application architecture](architecture.md): keep handlers small and dependencies explicit.
- [Recovery and migration](recovery.md): preserve evidence and rehearse rollback.
- [Performance testing](performance.md): measure the workload you intend to ship.
- [Troubleshooting](troubleshooting.md): find configuration, queue, and compatibility problems.

{% hint style="warning" %}
No shard alone can promise zero data loss across every infrastructure failure or exactly-once effects in another service. Design persistence, reconciliation, idempotency, and operational recovery together.
{% endhint %}
