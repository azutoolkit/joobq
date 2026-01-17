# JoobQ - Claude Code Context

## Project Overview

JoobQ is an enterprise-grade, high-performance asynchronous job queue system for the Crystal programming language. It processes up to 35,000 jobs/second using Redis-backed persistence and Crystal's fiber-based concurrency.

- **Version:** 0.4.1
- **License:** MIT
- **Crystal:** 1.17.1+
- **Dependencies:** redis, cron_parser

## Architecture Summary

### Core Components

| Component | File | Purpose |
|-----------|------|---------|
| Job | `src/joobq/job.cr` | Job module with status tracking, serialization, scheduling |
| Queue | `src/joobq/queue.cr` | Generic Queue(T) managing job lifecycle and workers |
| Worker | `src/joobq/worker.cr` | Fiber-based job processors with batch processing |
| RedisStore | `src/joobq/redis_store.cr` | Redis persistence with BRPOPLPUSH reliability |
| Scheduler | `src/joobq/scheduler.cr` | Cron and recurring job scheduling |
| Configure | `src/joobq/configure.cr` | Central configuration with DSL macros |

### Middleware Pipeline

- **Throttle** (`src/joobq/middlewares/throttle.cr`) - Rate limiting per queue
- **Retry** (`src/joobq/middlewares/retry.cr`) - Exponential backoff retry logic
- **Timeout** (`src/joobq/middlewares/timeout.cr`) - Job expiration handling

### Supporting Components

- **QueueFactory** - Runtime queue creation from YAML config
- **ErrorMonitor** - Error tracking and alerting system
- **DeadLetterManager** - Failed job management
- **APIServer** - REST API on port 8080

## Build and Test Commands

```bash
# Install dependencies
shards install

# Run all tests (requires Redis)
crystal spec

# Run specific test file
crystal spec spec/job_spec.cr

# Start Redis for testing
docker-compose up -d

# Build the project
crystal build src/joobq.cr

# Run with configuration
JOOBQ_ENV=development crystal run src/joobq.cr
```

## Code Conventions

### Naming

- Classes/Modules: `PascalCase` (e.g., `RedisStore`, `BaseQueue`)
- Methods/Variables: `snake_case` (e.g., `claim_jobs_batch`, `worker_id`)
- Constants: `SCREAMING_SNAKE_CASE` (e.g., `DELAYED_SET`, `BLOCKING_TIMEOUT`)
- Predicate methods: `?` suffix (e.g., `running?`, `past_expiration?`)
- State mutators: `!` suffix (e.g., `running!`, `dead!`, `stop!`)

### Crystal Idioms

- 2-space indentation
- Doc comments with `#` above declarations
- Use `getter`/`property` for instance variables with auto-generated accessors
- Generic types: `Queue(T)`, `Worker(T)` where T is job class
- JSON serialization via `include JSON::Serializable`
- Macros for DSL: `macro queue(...)`, `macro register_job(...)`

### Error Handling

- Custom exception classes: `ConfigValidationError`, `QueueFactoryError`
- Use `Log.error &.emit(...)` for structured logging
- ErrorContext class for rich error information
- Automatic retry with exponential backoff

## Key Files Reference

### Entry Points

- `src/joobq.cr` (198 lines) - Main entry point, module definition, configuration API
- `src/joobq/configure.cr` (324 lines) - Configuration DSL and settings

### Core Logic

- `src/joobq/job.cr` (233 lines) - Job module with status enum, enqueue methods
- `src/joobq/queue.cr` (198 lines) - Queue class, BaseQueue interface
- `src/joobq/worker.cr` (232 lines) - Worker with batch processing, error handling
- `src/joobq/redis_store.cr` (708 lines) - Redis operations, BRPOPLPUSH pattern

### Configuration

- `config/joobq.base.yml` - Base YAML configuration
- `config/joobq.test.yml` - Test environment configuration
- `src/joobq/yaml_config_loader.cr` - YAML loading and validation

### Testing

- `spec/spec_helper.cr` - Test setup with Redis, job registration
- `spec/helpers/all_test_jobs.cr` - Test job definitions

## Common Development Tasks

### Creating a New Job

1. Create class including `JoobQ::Job`
2. Define `@queue` name
3. Implement `perform` method
4. Register with `QueueFactory.register_job_type(MyJob)`

### Adding a Queue

Use macro in configuration:
```crystal
JoobQ.configure do
  queue "my_queue", 10, MyJob, {limit: 100, period: 1.minute}
end
```

### Creating Middleware

1. Create class including `JoobQ::Middleware`
2. Implement `matches?(job, queue)` - when to apply
3. Implement `call(job, queue, worker_id, next_middleware)` - middleware logic

## Environment Variables

| Variable | Purpose | Default |
|----------|---------|---------|
| `REDIS_HOST` | Redis server host | localhost |
| `REDIS_PORT` | Redis server port | 6379 |
| `REDIS_PASS` | Redis password | nil |
| `REDIS_POOL_SIZE` | Connection pool size | 500 |
| `REDIS_POOL_TIMEOUT` | Pool timeout seconds | 2.0 |
| `JOOBQ_ENV` | Environment (development/test/production) | development |
| `JOOBQ_CONFIG_PATH` | Custom config file path | auto-discovered |

## Job Status Flow

```
Enqueued -> Running -> Completed
    |          |
    v          v
Scheduled   Retrying -> Dead
    |          ^
    v          |
Expired -------+
```

## Redis Key Patterns

| Key | Purpose |
|-----|---------|
| `joobq:processing:{queue}` | Jobs being processed (list) |
| `joobq:delayed_jobs` | Scheduled/retry jobs (sorted set) |
| `joobq:dead_letter` | Failed jobs (sorted set) |
| `joobq:stats:processed` | Per-queue counts (hash) |
| `joobq:stats:completed` | Per-queue counts (hash) |
| `joobq:retry_lock:{jid}` | Idempotent retry locks |
| `joobq:error_counts` | Error counts (hash) |
| `joobq:recent_errors` | Error contexts (hash) |
