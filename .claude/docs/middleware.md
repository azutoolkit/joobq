# JoobQ Middleware Development

## Middleware Interface

```crystal
module JoobQ
  module Middleware
    # Return true if this middleware should process the job
    abstract def matches?(job : Job, queue : BaseQueue) : Bool

    # Process the job, call next_middleware to continue chain
    abstract def call(job : Job, queue : BaseQueue, worker_id : String, next_middleware : ->) : Nil
  end
end
```

## Creating Custom Middleware

```crystal
module JoobQ
  module Middleware
    class MyCustomMiddleware
      include Middleware

      def matches?(job : JoobQ::Job, queue : BaseQueue) : Bool
        # Return true to apply this middleware
        queue.name == "special"
      end

      def call(job : JoobQ::Job, queue : BaseQueue, worker_id : String, next_middleware : ->) : Nil
        # Pre-processing
        Log.info { "Processing job #{job.jid}" }

        begin
          next_middleware.call
          Log.info { "Job #{job.jid} completed" }
        rescue ex : Exception
          Log.error { "Job #{job.jid} failed: #{ex.message}" }
          raise ex
        end
      end
    end
  end
end
```

## Built-in Middlewares

### Throttle (`src/joobq/middlewares/throttle.cr`)
Rate limits job processing per queue based on `throttle_limit` configuration.

### Retry (`src/joobq/middlewares/retry.cr`)
Handles job failures with exponential backoff. Moves to dead letter when retries exhausted.

### Timeout (`src/joobq/middlewares/timeout.cr`)
Checks job expiration, moves expired jobs to dead letter queue.

## Registering Middleware

```crystal
JoobQ.configure do
  middlewares << MyCustomMiddleware.new
end
```

## Pipeline Order

Default: Throttle -> Retry -> Timeout -> Job.perform

## File Location

Place in `src/joobq/middlewares/{middleware_name_snake}.cr`
