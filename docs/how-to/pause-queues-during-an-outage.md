---
description: Stop workers from taking new jobs from a queue while a dependency is down, and start them again afterwards.
---

# Pause queues during an outage

*How-to · Core · JoobQUI*

## Prerequisites

- The queue's name, for example `emails` while your mail provider is down.
- One of: an operator role in JoobQUI, an operator API token for JoobQUI's `/api/v1`, or an Azu application with Azu CLI 0.1.62.

## Steps

1. Pause the queue, in one of these places:
   - **JoobQUI:** on **Queues**, click **Pause** on the queue.
   - **JoobQUI API:** `curl -X POST -H "Authorization: Bearer $JOOBQUI_TOKEN" $JOOBQUI/api/v1/queues/emails/pause`
   - **Azu CLI:** `azu jobs:pause --queue emails` (add `--force` in a script).
2. Let producers keep enqueueing: jobs wait in the queue, and jobs already running finish.
3. When the dependency is back, resume it the same way (**Resume**, `.../queues/emails/resume`, or `azu jobs:resume --queue emails`).

## Verify

The pause is a flag in Redis (`joobq:queue:<name>:paused`), and workers in every process see it within about half a second. Captured against a self-hosted JoobQUI, with the `test` queue:

```
$ curl -s -X POST -H "Authorization: Bearer $JOOBQUI_TOKEN" -w "%{http_code}\n" $JOOBQUI/api/v1/queues/test/pause
204
$ curl -s -H "Authorization: Bearer $JOOBQUI_TOKEN" $JOOBQUI/metrics | grep "joobqui_queue_paused{queue=\"test\"}"
joobqui_queue_paused{queue="test"} 1
$ curl -s -X POST -H "Authorization: Bearer $JOOBQUI_TOKEN" -w "%{http_code}\n" $JOOBQUI/api/v1/queues/test/resume
204
$ curl -s -H "Authorization: Bearer $JOOBQUI_TOKEN" $JOOBQUI/metrics | grep "joobqui_queue_paused{queue=\"test\"}"
joobqui_queue_paused{queue="test"} 0
```

On a Prometheus server, alert on `joobqui_queue_paused == 1` lasting longer than you expect an outage to last.

## See also

- [Queues and priorities](../explanation/queues-and-workers.md)
- [Triage, redrive and export dead letters](https://joobq-website.onrender.com/docs/how-to/triage-and-redrive-dead-letters): jobs that failed before you paused.
