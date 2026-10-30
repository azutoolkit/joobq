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
| `core/lifecycle.cr` | Delayed admission, one retry, DLQ inspection, selected replay after repair, clean shutdown |
| `pro/first_workflow.cr` | Typed input, activity registration, workflow result, Pro then Core shutdown |
| `pro/coordination.cr` | Sealed batch completion, duplicate rejection, owner-checked release, concurrent rate reservations |
| `pro/observability.cr` | Completion/busy counters, Redis metrics collection, collector shutdown |

Fragments marked as illustrative show an integration point; they are not standalone programs. The checker enforces that distinction. No private Pro implementation sources are copied into the public documentation.

## Validation record

Validated locally on **October 30, 2026**, Linux x86_64, Crystal **1.22.1**, Redis **8.0.2**, with the committed Core/Pro fixture dependency graphs:

- Five executable fixtures passed, including SIGTERM, retry/DLQ/replay, workflow results, coordination, and metrics shutdown. The fixture runtimes were roughly 0.1–3.4 seconds after compilation; these are test timings, not throughput benchmarks.
- GitBook navigation, internal links/anchors, code-block classification, exact quick-start source matching, and five checker regression tests passed.
- All **ten Mermaid diagrams** rendered to SVG using Mermaid **11.17.2** (installed with Mermaid CLI 11.12.0) in Chromium over a local HTTP preview. This is a syntax/render check, not a hosted GitBook preview.
- Azu CLI source at `v0.1.59` (`dbf1cc5aa949cbbfc507eec87ae6bed83c2af2a0`) was built locally. The generator/operator walkthrough passed against the Core fixture, including the explicitly empty worker registry in this release. CLI build dependencies used the existing development installation; the Core/Pro example graphs were installed from their release constraints and locked separately.

CI repeats Core fixtures in the public repository using Redis 8.0.6. The coordinated Pro repository workflow runs Pro fixtures against the documented release with authorized access; public fork CI does not require private credentials. Hosted CI status belongs to the pull requests and must be checked before merge.

These checks do not establish a production throughput guarantee, complete chaos coverage, deployment-specific TLS/failover behavior, or GitBook publication. Screenshot markers are editorial requests, not captured images. Mermaid rendering and GitBook sync status are reported separately.

## Workflow DSL preview checks

The [preview guide](pro/workflow-dsl/README.md) pins Pro implementation commit `901b21f928560ac3483c15d8dbc8505e91060c7f`. Its fixture, `examples/docs/preview/workflow_dsl.cr`, is checked against the book and the Pro example (apart from the local source require). The private Pro CI compiles and executes it against the feature source; the released Pro fixture job remains pinned to the released API.

Locally on October 30, 2026, Crystal 1.22.1 and Redis 8.0.2 passed the workflow example, 22 focused DSL specs with four workers and `-Dpreview_mt`, seven compile-failure contracts, and 15 offline builder/registration specs. The full Pro suite passed 441 tests before the final inherited-activity/aggregate-query test was added; that test passed in the focused suite. Offline tests used an unreachable Redis port and did not open a connection. The new workflow Mermaid diagram rendered in Chromium with Mermaid 11.17.2. These checks cover graph/hash parity, nested groups, lifecycle operations, typed registration conflicts, recovery, and build pinning. They do not certify deployment durability or performance.

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

Before publishing, connect the JoobQ repository's `.gitbook.yaml` to the intended GitBook space, review its preview (including diagrams and relative links), and verify a repository sync. A merged Markdown change alone does not prove that the hosted book updated.
