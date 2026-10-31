---
description: Reproduce the documentation checks and understand what they do not establish.
---

# Documentation validation

The [compatibility page](introduction/compatibility.md) records the release baselines. Executable fixtures live in `examples/docs/`; their committed lockfiles resolve Core and Pro separately. The quick-start Crystal code is checked byte-for-byte against its executable fixture.

## Run the checks

From the JoobQ repository:

```sh
python3 scripts/check_docs.py
python3 -m unittest discover -s scripts -p 'test_check_docs.py'
cd examples/docs/core
shards install --frozen
cd ../../..
python3 scripts/test_docs_examples.py --edition core
```

For authorized Pro developers:

```sh
cd examples/docs/pro
shards install --frozen
cd ../../..
python3 scripts/test_docs_examples.py --edition pro
```

Requirements: Crystal 1.22.1, Shards, Python 3.10+, Redis server, and the native libraries needed to build Crystal applications. Dependency installation requires network access and, for Pro, authorized repository access. The runner starts disposable loopback Redis with AOF, `appendfsync always`, and `noeviction`; it ignores inherited Redis and JoobQ environment settings. It never flushes your application Redis.

For the optional released CLI walkthrough (with an installed or built Azu CLI `v0.1.59`):

```sh
python3 scripts/test_docs_cli.py --azu /absolute/path/to/azu
```

This creates a temporary project, generates the JoobQ setup and a typed job, runs the example worker, and checks status, DLQ inspection, replay preview, pause/resume, and shutdown. It does not exercise the full Azu web application or interactive TUI.

## Coverage

| Fixture | Checks |
| --- | --- |
| `core/first_job.cr` | Documented job executes; SIGTERM exits cleanly |
| `core/thin_job.cr` | Business operation check, queued adapter execution, SIGTERM shutdown |
| `core/lifecycle.cr` | Delayed admission, one retry, DLQ inspection, selected replay after repair, clean shutdown |
| `pro/first_workflow.cr` | Typed DSL input, blueprint registration, checked workflow result, Pro then Core shutdown |
| `pro/workflow_dsl.cr` | Explicit result chaining, parallel receipt/timer branches, retry policy, checked result |
| `pro/approval_workflow.cr` | Signal payload, typed consumer, query, checked final result |
| `pro/compensation_workflow.cr` | Permanent payment failure and completed-step compensation |
| `pro/production_worker.cr` + `pro/worker_probe.cr` | Separate producer completes work, then worker exits on SIGTERM |
| `pro/coordination.cr` | Sealed batch completion, duplicate rejection, owner-checked release, concurrent rate reservations |
| `pro/observability.cr` | Completion/busy counters, Redis metrics collection, collector shutdown |

Fragments marked as illustrative show an integration point; they are not standalone programs. The checker enforces that distinction. No private Pro implementation sources are copied into the public documentation.

## Validation record

The original book baseline (Core v0.5.1 / Pro v0.2.0) was validated locally on **October 30, 2026**, Linux x86_64, Crystal **1.22.1**, Redis **8.0.2**:

- Five executable fixtures passed, including SIGTERM, retry/DLQ/replay, workflow results, coordination, and metrics shutdown. The fixture runtimes were roughly 0.1–3.4 seconds after compilation; these are test timings, not throughput benchmarks.
- GitBook navigation, internal links/anchors, code-block classification, exact quick-start source matching, and five checker regression tests passed.
- All **ten Mermaid diagrams** rendered to SVG using Mermaid **11.17.2** (installed with Mermaid CLI 11.12.0) in Chromium over a local HTTP preview. This is a syntax/render check, not a hosted GitBook preview.
- Azu CLI source at `v0.1.59` (`dbf1cc5aa949cbbfc507eec87ae6bed83c2af2a0`) was built locally. The generator/operator walkthrough passed against the Core fixture, including the explicitly empty worker registry in this release. CLI build dependencies used the existing development installation; the Core/Pro example graphs were installed from their release constraints and locked separately.

CI repeats Core fixtures in the public repository using Redis 8.0.6. The coordinated Pro repository workflow runs Pro fixtures against the documented release with authorized access; public fork CI does not require private credentials. Hosted CI status belongs to the pull requests and must be checked before merge.

These checks do not establish a production throughput guarantee, complete chaos coverage, deployment-specific TLS/failover behavior, or GitBook publication. Screenshot markers are editorial requests, not captured images. Mermaid rendering and GitBook sync status are reported separately.

## Workflow DSL release checks

The [DSL guide](pro/workflow-dsl/README.md) and the workflow fixtures target **Pro v0.2.2**, release commit `92879b94a3be2580e749f3a0acc829b9276040dc`. `examples/docs/pro/workflow_dsl.cr` is checked against the book and Pro's example (apart from the local source require). The private Pro documentation workflow pins this release, compiles all eight Pro fixture programs, and runs them against disposable Redis. The public Core job never needs private Pro access.

Validated locally on **October 30, 2026** with Crystal **1.22.1** and Redis **8.0.2**: all **eleven** current fixture programs passed (three Core, eight Pro), including approval/query, compensation, a separate producer/worker probe, coordination, observability, retry/DLQ/replay, and SIGTERM shutdown. Dependencies were installed from the frozen Core v0.5.1 and Pro v0.2.2 fixture graphs. The GitBook checker and its five regression tests passed. All 17 Mermaid diagrams rendered in Chromium with Mermaid 11.17.2. The Kubernetes manifest parsed successfully, with matching selectors, volume references, and shutdown budget checks; it was not applied to a cluster. The systemd unit and managed-cloud topology remain deployment recipes to validate in your own environment.

Use `python3 scripts/test_docs_examples.py --edition pro` after installing the frozen Pro fixture graph to repeat the Pro checks, including the producer probe before worker shutdown.

The supporting DSL implementation was validated on October 30, 2026 with Crystal 1.22.1 and Redis 8.0.2: the workflow example, 22 focused DSL specs with four workers and `-Dpreview_mt`, seven compile-failure contracts, and 15 offline builder/registration specs. The final full Pro regression suite passed 442 tests, with no failures, errors, or pending tests. Offline tests used an unreachable Redis port and did not open a connection. The new workflow Mermaid diagram rendered in Chromium with Mermaid 11.17.2. These checks cover graph/hash parity, nested groups, lifecycle operations, typed registration conflicts, recovery, and build pinning. They do not certify deployment durability or performance.

In the Pro source checkout:

```sh
shards install --frozen
python3 scripts/test_workflow_dsl_compilation.py
python3 lib/joobq/scripts/run_integration.py crystal spec spec/workflows/dsl
crystal build examples/workflow_dsl.cr -o /tmp/workflow-dsl-example
python3 lib/joobq/scripts/run_integration.py --probe /tmp/workflow-dsl-example
```

## Maintaining the book

Keep every page in `SUMMARY.md`, preserve existing URLs where practical, and update the compatibility matrix when changing dependencies. Use titled code blocks, focused hints, and diagrams where they explain a boundary. Keep credentials, private internals, and licensing implementation out of public examples.

Generate Crystal API reference output into ignored `docs/api/` (for example, `crystal docs --output docs/api`), rather than mixing generated HTML with authored GitBook pages.

For Site Git Sync, use the root `gitbook-docs.yaml`, which maps the unified book to `docs/`. The existing `.gitbook.yaml` and `docs/SUMMARY.md` retain the book navigation. Review the GitBook preview (including diagrams and relative links) and verify a repository sync before claiming publication. A merged Markdown change alone does not prove that the hosted book updated.
