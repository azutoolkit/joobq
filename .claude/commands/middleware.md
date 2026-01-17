---
description: Create a custom JoobQ middleware component
---

# Create Middleware

Create a new middleware for the JoobQ pipeline.

## Information Needed

1. **Middleware name** (e.g., `Logging`, `RateLimit`, `Metrics`)
2. **Match condition** (when to apply: all jobs, specific queues, etc.)
3. **Processing logic** (what to do before/after job execution)

## Template

```crystal
module JoobQ
  module Middleware
    class {MiddlewareName}
      include Middleware

      def matches?(job : JoobQ::Job, queue : BaseQueue) : Bool
        # Return true to apply this middleware
        {match_condition}
      end

      def call(job : JoobQ::Job, queue : BaseQueue, worker_id : String, next_middleware : ->) : Nil
        # Pre-processing
        {pre_processing}

        begin
          next_middleware.call

          # Post-processing on success
          {post_success}
        rescue ex : Exception
          # Error handling
          {error_handling}
          raise ex
        end
      end
    end
  end
end
```

## File Location

Place in `src/joobq/middlewares/{middleware_name_snake}.cr`

## Registration

Add to middleware pipeline in `src/joobq/configure.cr`:

```crystal
property middlewares : Array(Middleware) = [
  Middleware::Throttle.new,
  Middleware::{MiddlewareName}.new,
  Middleware::Retry.new,
  Middleware::Timeout.new,
] of Middleware
```

## Testing

Create spec at `spec/middleware_{name}_spec.cr`:

```crystal
describe JoobQ::Middleware::{MiddlewareName} do
  it "matches expected jobs" do
    middleware = JoobQ::Middleware::{MiddlewareName}.new
    middleware.matches?(job, queue).should be_true
  end

  it "calls next middleware" do
    called = false
    next_middleware = -> { called = true }
    middleware.call(job, queue, "worker-1", next_middleware)
    called.should be_true
  end
end
```
