---
description: The JoobQ commands of Azu CLI 0.1.62 and their options, as `azu <command> --help` prints them, and the keys of the terminal dashboard.
---

# Azu CLI and terminal dashboard

*Reference · Core · Pro*

JoobQ itself ships no command-line tool. These commands come from Azu CLI 0.1.62 and run inside an Azu application. Every `jobs:*` command also takes `--redis URL`, `--boot FILE`, `-e`/`--env NAME`, `-v`/`--verbose` and `-h`/`--help` (`jobs:ui` uses `-h` for `--host`, so its help is `--help` only).

| Command | Description | Options |
| --- | --- | --- |
| `azu jobs:worker` | Start background job workers | `-w N, --workers N` Workers per queue (1..1000); otherwise preserve configuration<br>`-q LIST, --queues LIST` Comma-separated queue selection; otherwise all configured queues<br>`-d, --daemon` Unsupported: use a service supervisor<br>`--release` Compile an optimized worker<br>`--api` Enable management API; requires JoobQ tokens<br>`--shutdown-timeout SECONDS` Graceful drain timeout (1..3600, default 25) |
| `azu jobs:status` | Show job queue status | `--json` Print machine-readable results<br>`-q NAME, --queue NAME` Queue name (default: default) |
| `azu jobs:clear` | Clear job queues | `--json` Print machine-readable results<br>`-q NAME, --queue NAME` Queue name (default: default)<br>`-f, --force` Confirm mutation without prompting<br>`--dry-run` Preview without modifying jobs<br>`--all` All configured queues<br>`--failed` Purge DLQ entries instead of waiting jobs |
| `azu jobs:retry` | Retry failed jobs | `--json` Print machine-readable results<br>`-q NAME, --queue NAME` Queue name (default: default)<br>`-f, --force` Confirm mutation without prompting<br>`--dry-run` Preview without modifying jobs<br>`--all` Retry selected queue's DLQ (maximum 1000)<br>`-l N, --limit N` Maximum jobs (1..1000, default 1) |
| `azu jobs:ui` | Start JoobQUI web interface | `-p PORT, --port PORT` HTTP port<br>`-h HOST, --host HOST` Bind address<br>`--path DIRECTORY` JoobQUI checkout with installed dependencies |
| `azu jobs:dlq` | List dead-letter job IDs | `--json` Print machine-readable results<br>`-q NAME, --queue NAME` Queue name (default: default)<br>`--limit N` Page size (1..1000)<br>`--offset N` Zero-based offset |
| `azu jobs:pause` | Pause queue claims | `--json` Print machine-readable results<br>`-q NAME, --queue NAME` Queue name (default: default)<br>`-f, --force` Confirm mutation without prompting<br>`--dry-run` Preview without modifying jobs |
| `azu jobs:resume` | Resume queue claims | `--json` Print machine-readable results<br>`-q NAME, --queue NAME` Queue name (default: default)<br>`-f, --force` Confirm mutation without prompting<br>`--dry-run` Preview without modifying jobs |
| `azu joobq` | Terminal dashboard for queues, workflows and dead letters | `--boot PATH` |
| `azu generate joobq` | Generate the JoobQ initializer, configuration, example job and worker | `--redis URL`, `--queue NAME`, `--workers N` (1 to 1000), `--no-example`, `--force` |
| `azu generate job <Name> [field:type ...]` | Generate a job class | `--force` |

Mutating commands (`jobs:pause`, `jobs:resume`, `jobs:retry`, `jobs:clear`) take `-f`/`--force` ("Confirm mutation without prompting") and `--dry-run` ("Preview without modifying jobs").

## `azu joobq` keys

| Key | Action |
| --- | --- |
| `1`, `2`, `3` | Queues, workflows, dead letters |
| `[` / `]` | Previous / next tab |
| Tab | Switch pane |
| Arrows, PgUp / PgDn | Scroll the focused pane |
| `r`, then `y` | Replay the selected dead letter |
| `q`, Ctrl-C | Quit |

## See also

- [Use JoobQ in an Azu application](../how-to/use-joobq-in-azu.md)
- [CLI commands and host binaries](https://joobq-website.onrender.com/docs/reference/cli-commands): the JoobQUI binary's tasks.
