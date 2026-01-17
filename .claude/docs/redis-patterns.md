# JoobQ Redis Interaction Patterns

## Connection Pool

```crystal
RedisStore.new(
  host: "localhost",
  port: 6379,
  pool_size: 500,
  pool_timeout: 2.0
)
```

## Reliable Queue Pattern (BRPOPLPUSH)

```crystal
job_json = redis.brpoplpush(queue_name, processing_key, timeout)
```

## Key Structure

| Key Pattern | Type | Description |
|-------------|------|-------------|
| `{queue_name}` | List | Main job queue |
| `joobq:processing:{queue}` | List | Jobs being processed |
| `joobq:delayed_jobs` | Sorted Set | Scheduled jobs (score = execution time) |
| `joobq:dead_letter` | Sorted Set | Failed jobs |
| `joobq:stats:processed` | Hash | Per-queue counts |
| `joobq:retry_lock:{jid}` | String | Idempotent retry locks |

## Pipelined Operations

```crystal
redis.pipelined do |pipe|
  pipe.lrem(processing_key, 0, job_json)
  pipe.hincrby("joobq:stats:completed", queue_name, 1)
end
```

## Batch Operations

```crystal
store.enqueue_batch(jobs, batch_size: 100)
store.queue_sizes_batch(["queue1", "queue2"])
store.claim_jobs_batch(queue_name, count: 5)
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `REDIS_HOST` | localhost | Redis host |
| `REDIS_PORT` | 6379 | Redis port |
| `REDIS_POOL_SIZE` | 500 | Pool size |
