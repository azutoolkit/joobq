---
description: Configure a new JoobQ queue with workers and optional throttling
---

# Configure Queue

Add a new queue configuration.

## Information Needed

1. **Queue name** (e.g., `emails`, `notifications`)
2. **Worker count** (1-1000, typically 5-20)
3. **Job class** (must exist and be registered)
4. **Throttle settings** (optional): limit per period

## Programmatic Configuration

```crystal
JoobQ.configure do
  # Without throttling
  queue "{queue_name}", {workers}, {JobClass}

  # With throttling
  queue "{queue_name}", {workers}, {JobClass}, {limit: {limit}, period: {period}}
end
```

## YAML Configuration

Add to `config/joobq.{env}.yml`:

```yaml
joobq:
  queues:
    {queue_name}:
      job_class: "{JobClass}"
      workers: {workers}
      # Optional throttling
      throttle:
        limit: {limit}
        period: "{period}"
```

## Registration Checklist

1. Job class exists and includes `JoobQ::Job`
2. Job registered: `QueueFactory.register_job_type({JobClass})`
3. Queue added to configuration
4. Test queue exists in `config/joobq.test.yml`

## Queue Methods

```crystal
queue = JoobQ["{queue_name}"]
queue.start           # Start workers
queue.stop!           # Stop workers
queue.running?        # Check status
queue.size            # Jobs in queue
```
