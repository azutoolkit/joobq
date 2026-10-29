# PR #19 reconciliation with the enterprise v1 plan

Reviewed 2026-10-29: [azutoolkit/joobq PR #19](https://github.com/azutoolkit/joobq/pull/19), Git head **`498ac5f5f0c7e78f35f9fd380f2290495c3022e1`**. This supplements, rather than rewrites, the historical audit at `b38961d`. The implementation plan now treats this PR's work as an integration dependency, not work to reimplement.

## Source and validation boundaries

Fetched `refs/pull/19/head` directly and inspected its commits/diff. The PR head contains the merge of PR #18's Redis URL/TLS/ACL work and the strict queue/store-wiring changes. Relative to the fetched master, the merge base is `6c70213427d411feee10f40806ec1d47a8716c8f`; master is `b38961d62ef1d70237a6f701b9af8ff34c9dbe8b`. The PR head is not an ancestor of that fetched master. Do not infer GitHub merge/review/check status from Git refs: `gh pr view` was denied by the GraphQL API, so hosted checks, PR body and approval state were not verified.

Used a detached, unchanged review worktree at `/workspace/scratch/joobq-pr19-review`, with the installed Redis 2.9.1/pool 0.2.4/cron_parser 0.4.0 dependency graph. The earlier audit branches were not rebased or merged in this planning update. The original full-suite results therefore do not validate the combined branch.

## Work already implemented in the PR

| Area | Source/tests inspected | Credit to the plan | Remaining enterprise obligation |
| --- | --- | --- | --- |
| Configured store lookup | `JoobQ.configured_store?`, `RedisStore.instance`; `store_wiring_spec.cr` | P02 / F22: singleton defaults now resolve the configured RedisStore; new consumers follow replacement config | Multiple independent runtimes, preconstructed consumers, non-Redis Store fallback, explicit Pro history/activity routing and global Runtime isolation still need coverage/design |
| Strict enqueue | `Queue#add!`, `JoobQ.enqueue`, `UnknownQueue`; `strict_enqueue_spec.cr` | P04 / F05: malformed JSON/unknown queues raise; success returns jid; named queue overrides payload-selected Redis key | Legacy add/batch paths still swallow errors or trust payload queue; no durable request receipt, Unknown outcome resolution, deduplicated admission or per-item batch contract |
| Strict delayed enqueue | `Queue#add_delayed(job, at:)`; strict enqueue specs | P04/P06 / F06: validate, force the selected queue, set Scheduled and persist the scheduled time | This is producer scheduling, not a fix for destructive promotion, ownership, delayed fairness or receipt-based replay |
| Redis endpoint/config parsing | `RedisEndpoint`, `RedisStore.from_env`, URL constructor, config mapper/merge; endpoint/config specs | P03/P13 / F10: redis/rediss/unix, ACL credentials, database, URL precedence, merged YAML, malformed-URL rejection and no silent plaintext fallback | Uniform deadlines/settings across both constructors, fail-closed production policy for disabled verification, migration from old environment examples, full graph CI |
| TLS verification | `RedisEndpoint#ssl_context` and host/IP verification; hostname and real Redis TLS specs | P13 / F10: CA chain and host/IP verification implemented; old SSL/TLS versions disabled, additional CA accepted, explicit insecure opt-out | Certificate rotation/expiry/revocation policy, target infrastructure coverage and SNI support or an explicit endpoint limitation; shard currently sends no SNI |
| ACL/reconnect protection | `RedisClient#connect`; URL store specs | P03/P13 / F10/F14: username/password AUTH and SELECT on reconnect; close failed-auth connections rather than run as default user; password-safe inspect on URL clients/pools | Successful adoption of rotated credentials and bounded drain, exact production ACL permissions for every Lua path, legacy pooled-client inspect redaction |
| Management API migration marker | Deprecated POST `/joobq/jobs` header; API parameter specs | P13 / F13: deprecation and suggested strict API replacement exist | Route remains unauthenticated; deprecation is not authorization. Private defaults, auth integration, roles, limits and audit trail remain open |

No changes in this PR provide distributed claim leases, token-checked settlement, bounded job execution, a durable workflow effect journal, completed Pro batches/uniqueness/rate limiting, Prometheus/OTel exporters, migration/restore evidence or a 35k settled-job benchmark. Those work packages remain required.

## New integration issue: F32 — CI URL becomes invalid

The PR's `.github/workflows/crystal.yml` still contains:

```yaml
REDIS_URL: redis:6379
```

The strict parser expects a URL with a host, e.g. `redis://redis:6379/0`. Local startup with the workflow's value failed with **`Redis URL has no host`** (`JoobQ::ConfigLoadError`, exit 1), before Redis connectivity could matter. This is a local reproduction of the configuration incompatibility, not an assertion that a hosted run was inspected.

P00 must fix the CI value to a valid URL, or remove REDIS_URL and deliberately test the host/port path. Then test both configuration paths. Search deployment examples/fixtures for the old value, including the local audit branch's copy of this workflow. Do not relax the parser to hide the error or introduce a fallback to plaintext.

## Integration hazards to resolve once

1. Adopt the reviewed PR #19 head as the feature baseline, integrate with current master, then replay only the distinct local hardening patches. Keep strict APIs and URL/YAML/security behavior intact. Record final combined SHA before rerunning suites.
2. `redis_store.cr` overlaps: retain PR #19's configured-store lookup and URL constructor alongside destination-first promotion/DLQ fixes. Our earlier timeouts modified the legacy host/port constructor only. PR #19's `RedisClient` accepts a command timeout but defaults to nil; `RedisPool` does not pass one. Thread the transport policy through **both** constructors, RedisPool, RedisClient, DNS/TLS/AUTH/SELECT and reconnect. A passing legacy timeout test cannot close the URL-path gate.
3. Retain README corrections to unsupported performance/durability claims while preserving the new URL/TLS/ACL docs. Update legacy credential-inspection limitations only after fixing/testing them.
4. Retain PR #19's positive two-server store-wiring assertions. Do not restore the old characterization that expected misrouting. Broaden the test to independent Pro runtimes and consumers created before/after configuration changes.
5. `BaseQueue` now requires `add!` and `add_delayed`. Compile custom queue implementations/test doubles and Pro/ecosystem consumers against the paired graph; document the extension-interface change.
6. Make real TLS and second-server tests mandatory in release CI. Current workflow provisions neither the opt-in TLS Redis nor the second server; hostname test setup can also mark tests pending when OpenSSL setup fails. Required infrastructure failures must fail CI.
7. Define close/drain semantics across both store constructors. PR's `close` handles URL pools only and permits later commands to reconnect; it is not a shutdown admission fence or a proven safe close during in-flight I/O.

## Local validation performed

Crystal **1.22.1**, **4 workers**, Redis **8.0.2**. Three owned disposable Redis fixtures: primary, second store and a real TLS Redis. A temporary private CA issued a certificate for localhost/127.0.0.1; 127.0.0.2 reached the same server for hostname mismatch testing. No production/shared Redis was reset. Fixtures were configured for functional tests with persistence disabled, so this run establishes no durability claim.

Ran these exact spec files on the unmodified PR head:

```text
spec/redis_endpoint_spec.cr
spec/redis_store_url_spec.cr
spec/redis_url_config_spec.cr
spec/redis_tls_hostname_spec.cr
spec/redis_tls_spec.cr
spec/store_wiring_spec.cr
spec/strict_enqueue_spec.cr
spec/api_param_routes_spec.cr
```

**76 examples, 0 failures, 0 errors, 0 pending.** Coverage includes real TLS acceptance, bad-host and untrusted-CA rejection, ACL restrictions, password-rotation failure remaining fail-closed, strict queue routing and actual two-server configured-store isolation. The controlled credential-rotation test proves refusal of stale credentials; it does not prove automatic successful secret refresh.

Reproduction requires disposable Redis servers and these variables (substitute their actual ports/CA path):

```sh
REDIS_HOST=127.0.0.1
REDIS_PORT=<primary-port>
JOOBQ_SPEC_SECOND_REDIS_PORT=<second-port>
JOOBQ_SPEC_TLS_REDIS_URL=rediss://localhost:<tls-port>
JOOBQ_SPEC_TLS_CA_FILE=<temporary-ca.pem>
CRYSTAL_WORKERS=4
```

Unset REDIS_URL for this focused run to exercise fixture-selected configuration. Separately reproduced the invalid CI URL with `REDIS_URL=redis:6379 crystal eval 'require "./src/joobq"; JoobQ::RedisStore.from_env'` (expected failure). Fresh dependency resolution, full core/Pro suites on the combined tree, hosted CI, certificate/credential refresh, total deadlines and load/HA remain unverified here.
