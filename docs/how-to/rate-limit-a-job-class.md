---
description: Limit how often a job class starts across every worker process, with Pro's rate limiter.
---

# Rate-limit a job class

*How-to · Pro*

## Prerequisites

- Pro installed ([Add Pro](add-pro.md)).
- The limit you need, as a count per period between 1 ms and 24 hours.

## Steps

1. Include `JoobQPro::RateLimited` in the job and declare the limit with `rate_limit count:, period:`.
2. Add `JoobQPro::RateLimitMiddleware.new` to `config.middlewares` with `unshift`; it is not installed by default.
3. The limit counts starts of this job class. To keep separate counts per account or region, pass `key_suffix:`, or define `queue_name` on the job; either is appended to the class name in the Redis key.

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

## Verify

Output of `LOG_LEVEL=fatal crystal run rate_limit.cr` (four workers, six jobs):

```
Request 6 at 0.6s
Request 1 at 0.6s
Request 3 at 2.1s
Request 2 at 2.1s
Request 5 at 4.1s
Request 4 at 4.1s
PASS 6 requests, at most 2 per second
```

No more than two requests start in any one-second window, whatever the number of workers or processes. Jobs that found the window full were put back in the delayed set without using a retry.

## See also

- [Rate limiting and throttling](../explanation/rate-limiting-and-throttling.md): the limiter, Core's throttle and their limits.
