---
description: Inspect Core and Pro through the same command center.
---

# CLI and terminal management

Azu CLI is optional and works with Core. Pro adds workflow data when its runtime store is configured; installing the CLI does not enable Pro.

| Command | Purpose | Requirement |
| --- | --- | --- |
| `azu jobs:status --json` | Queue statistics and worker-registry data | Application boot and supported Core APIs |
| `azu jobs:worker` | Start foreground queue workers | Registered queues |
| `azu joobq` | Standalone terminal dashboard | Application-side provider |
| `azu dev` | Development HUD with job activity | Running Azu app and its telemetry setup |
| `azu jobs:ui` | Start the separate web interface | Optional JoobQUI dependency/configuration; not the TUI |

## Inspect first

```sh
azu jobs:status --queue orders --json
azu jobs:dlq --queue orders --limit 20 --json
azu joobq
```

The adapter boots your configured job classes. It must not call `forge` or start another server. A connected Redis indicator is not a healthy-worker indicator. Missing provider data stays unavailable.

## Terminal keys

| Key | Action in standalone `azu joobq` |
| --- | --- |
| `1`, `2`, `3` | Queues, workflows, dead letters |
| `[` / `]` | Previous/next view; also useful inside `azu dev` |
| Tab / left / right | Change focused pane |
| Up / down, PgUp / PgDn | Move through the focused viewport |
| `r`, then `y` | Confirm replay of the selected dead letter |
| `q` / Ctrl-C | Exit and restore the terminal |

## Changes require review

```sh
azu jobs:retry --queue orders --limit 1 --dry-run
azu jobs:pause --queue orders
azu jobs:resume --queue orders
```

Pause/resume and replay prompt interactively. Use `--force` only when an automation system has already made the intended decision. Pause does not stop a side effect already running. Avoid bulk clearing as a recovery technique.

The development boot adapter is not a production security boundary. Use the CLI's documented read-only remote monitoring for observation, and separately authorized operational tooling for changes. Management API role tokens are described in [Access](../configuration/access.md).

[Screenshot: azu joobq with the workflows tab selected, a run and its step tree visible, keyboard hints along the bottom, and any missing provider shown as unavailable rather than zero.]

Full options: [Azu CLI jobs reference](https://azutopia.gitbook.io/azu-cli/command-reference/azu-jobs) and [terminal dashboard](https://azutopia.gitbook.io/azu-cli/command-reference/azu-joobq).
