# JoobQ Queue Configuration

## Programmatic Configuration

```crystal
JoobQ.configure do
  # Basic queue: name, workers, job_class
  queue "emails", 10, EmailJob

  # With throttling: limit jobs per period
  queue "notifications", 5, NotificationJob, {limit: 100, period: 1.minute}

  # High-priority queue with more workers
  queue "critical", 20, CriticalJob
end
```

## YAML Configuration

File: `config/joobq.yml`

```yaml
joobq:
  settings:
    default_queue: "default"
    retries: 3
    timeout: "2 seconds"
    timezone: "America/New_York"
    worker_batch_size: 10
    pipeline_batch_size: 100

  queues:
    emails:
      job_class: "EmailJob"
      workers: 10

    notifications:
      job_class: "NotificationJob"
      workers: 5
      throttle:
        limit: 100
        period: "1 minute"

    critical:
      job_class: "CriticalJob"
      workers: 20

  middlewares:
    - type: "throttle"
    - type: "retry"
    - type: "timeout"

  features:
    rest_api: true
    stats: true

  redis:
    host: "localhost"
    port: 6379
    pool_size: 500
```

## Queue Properties

| Property | Type | Description |
|----------|------|-------------|
| `name` | String | Unique queue identifier |
| `total_workers` | Int32 | Number of worker fibers (1-1000) |
| `throttle_limit` | NamedTuple? | `{limit: Int32, period: Time::Span}` |
| `job_type` | T | Generic type parameter for Queue(T) |

## Queue Methods

```crystal
queue = JoobQ["my_queue"]

# Lifecycle
queue.start           # Start workers
queue.stop!           # Stop workers gracefully

# Status
queue.running?        # Check if running
queue.size            # Jobs in queue
queue.running_workers # Active worker count

# Operations
queue.clear           # Clear all jobs
queue.pause           # Pause processing
queue.resume          # Resume processing
```

## Multi-Environment Configuration

### Base Configuration (`config/joobq.base.yml`)

```yaml
joobq:
  settings:
    default_queue: "default"
    retries: 3
  queues:
    default:
      job_class: "DefaultJob"
      workers: 5
```

### Development (`config/joobq.development.yml`)

```yaml
joobq:
  settings:
    timeout: "10 seconds"
  redis:
    host: "localhost"
```

### Production (`config/joobq.production.yml`)

```yaml
joobq:
  settings:
    timeout: "2 seconds"
    worker_batch_size: 20
  redis:
    host: "redis.example.com"
    pool_size: 1000
```

## Loading Configuration

```crystal
# Auto-discovery (finds joobq.yml in current/parent dirs)
JoobQ.initialize_config

# Explicit path
JoobQ.initialize_config_with("config/joobq.yml")

# Multiple sources (merged in order)
JoobQ.initialize_config_with(
  "config/joobq.base.yml",
  "config/joobq.#{ENV["JOOBQ_ENV"]}.yml"
)

# Hybrid: YAML base + programmatic overrides
JoobQ.configure(hybrid: true) do
  # Additional queues not in YAML
  queue "special", 3, SpecialJob
end
```

## Queue Registration Checklist

1. Job class exists and includes `JoobQ::Job`
2. Job registered: `QueueFactory.register_job_type(JobClass)`
3. Queue added to configuration (YAML or programmatic)
4. Test queue exists in `config/joobq.test.yml`

## Throttling Configuration

Throttling limits job processing rate:

```crystal
# Process max 100 jobs per minute
queue "rate_limited", 10, MyJob, {limit: 100, period: 1.minute}

# Process max 10 jobs per second
queue "slow_queue", 5, MyJob, {limit: 10, period: 1.second}
```

In YAML:

```yaml
queues:
  rate_limited:
    job_class: "MyJob"
    workers: 10
    throttle:
      limit: 100
      period: "1 minute"
```
