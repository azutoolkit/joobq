---
description: Core's per-process queue throttle and Pro's cross-process rate limiter, and which one protects a shared API.
---

# Rate limiting and throttling

*Explanation · Core · Pro*

JoobQ has two controls for "not too fast". Core's queue throttle spaces job starts inside one process; Pro's `RateLimiter` counts starts in Redis, so every process that serves a job class shares one limit.

## When to use it

- **Stay under an SMS provider's limit from one worker process.** A Core throttle of 2 per second on the `sms` queue.
- **Share a partner API's quota across five worker pods.** A Pro rate limit on the job class, counted in Redis.
- **Back off without burning retries.** A Pro rate-limited job that finds the window full is put back for later; it does not count as a failure.

## How it works

```mermaid
flowchart LR
  subgraph Core throttle, per process
    C1[worker] --> T{last start in this process less than period/limit ago?}
    T -->|yes| Sleep[sleep the rest] --> Run1[perform]
    T -->|no| Run1
  end
  subgraph Pro rate limit, all processes
    P1[worker in any process] --> L{Redis window for the key has room?}
    L -->|yes| Run2[perform]
    L -->|no| Later[(delayed set, retry after the window)]
  end
```

The Core throttle is a middleware that remembers, per queue, when the last job started in this process, and sleeps until `period / limit` has passed. The Pro limiter is a sliding window kept in a Redis sorted set and reserved atomically by a Lua script; a job that gets no permit goes back to the delayed set and is checked again about a second after its window frees.

## Example

Core throttle, 2 per second on a queue with 4 workers:

<!-- example: core/throttle.cr -->
```crystal
require "joobq"

STARTED = Time.instant

struct SendSmsJob
  include JoobQ::Job

  @queue = "sms"
  @@sent = Atomic(Int32).new(0)
  getter message_id : Int32

  def initialize(@message_id : Int32)
  end

  def self.sent
    @@sent.get
  end

  def perform
    puts "SMS #{message_id} at #{(Time.instant - STARTED).total_seconds.round(1)}s"
    @@sent.add(1)
  end
end

JoobQ.configure do |config|
  config.rest_api_enabled = false
  # At most 2 per second in this process: one job every 500 ms, whatever the worker count.
  queue "sms", 4, SendSmsJob, {limit: 2, period: 1.second}
end

5.times { |id| SendSmsJob.enqueue(message_id: id + 1) }
spawn { JoobQ.forge(trap_signals: false) }
until SendSmsJob.sent == 5
  sleep 50.milliseconds
end
JoobQ.shutdown(5.seconds)
puts "throttled: 5 jobs"
```

Output of `crystal run throttle.cr` (log lines omitted):

```
SMS 5 at 0.5s
SMS 4 at 1.0s
SMS 3 at 1.5s
SMS 2 at 2.0s
SMS 1 at 2.5s
throttled: 5 jobs
```

Pro rate limit, 2 per second on the job class, shared through Redis (run with the Pro fixtures; not executed in CI):

<!-- example: pro/rate_limit.cr -->
```crystal
require "joobq_pro"

STARTED = Time.instant

struct CallPartnerApiJob
  include JoobQ::Job
  include JoobQPro::RateLimited

  @queue = "partner-api"
  @@calls = Atomic(Int32).new(0)
  rate_limit count: 2, period: 1.second
  getter request_id : Int32

  def initialize(@request_id : Int32)
  end

  def self.calls
    @@calls.get
  end

  def perform
    puts "Request #{request_id} at #{(Time.instant - STARTED).total_seconds.round(1)}s"
    @@calls.add(1)
  end
end

JoobQ.configure do |config|
  config.rest_api_enabled = false
  # Not installed by default: add it yourself, before the retry middleware.
  config.middlewares.unshift(JoobQPro::RateLimitMiddleware.new)
  queue "partner-api", 4, CallPartnerApiJob
end

6.times { |id| CallPartnerApiJob.enqueue(request_id: id + 1) }
spawn { JoobQ.forge(trap_signals: false) }
until CallPartnerApiJob.calls == 6
  sleep 50.milliseconds
end
JoobQ.shutdown(5.seconds)
puts "PASS 6 requests, at most 2 per second"
```

Output of `LOG_LEVEL=fatal crystal run rate_limit.cr`:

```
Request 6 at 0.6s
Request 1 at 0.6s
Request 3 at 2.1s
Request 2 at 2.1s
Request 5 at 4.1s
Request 4 at 4.1s
PASS 6 requests, at most 2 per second
```

Two requests start per window. The deferred ones wait in the delayed set, which is checked once a second, so they start a little after the window frees rather than exactly at it.

## Options

| Parameter | Type | Default | Description |
| --- | --- | --- | --- |
| `throttle` (4th `queue` argument) | `{limit: Int32, period: Time::Span}` | `nil` | Core: starts spaced `period / limit` apart, per queue, per process |
| `rate_limit count:, period:, key_suffix:` | macro in a `JoobQPro::RateLimited` job | none | Pro: at most `count` starts per `period` (1 ms to 24 h), across processes |
| key | `String` | job class, lowercased, `::` as `_` | Redis key `joobq_pro:rate_limit:v1:<key>`; `key_suffix` or the job's `queue_name` is appended |
| `JoobQPro::RateLimitMiddleware` | middleware | not installed | Add it to `config.middlewares` yourself |
| `JoobQPro::RateLimiter.reserve(key, limit)` | method | none | Reserve a permit from your own code; returns `Permit(allowed, retry_after_ms)` |

{% hint style="warning" %}
A Core throttle in each of five processes allows five times the limit. A Pro permit is used up even when the job then fails, and a Redis error denies the permit. Jobs run by Core's opt-in Delivery runtime never go through `config.middlewares`, so the Pro middleware does not limit them. Activity-level rate limits are **Roadmap**.
{% endhint %}

{% hint style="info" %}
**JoobQUI.** When a partner asks you to stop altogether, pause the queue from the console's Queues page. The pause flag lives in Redis (`joobq:queue:<name>:paused`), so workers in every process stop claiming within about half a second.
{% endhint %}

## Next steps

- [Workers and concurrency](workers-and-concurrency.md): limit jobs at once instead of starts per second.
- [Add Pro](../how-to/add-pro.md): add `joobq_pro` to the application.
- [Batches and unique jobs](distributed-coordination.md): the other Pro coordination services.
