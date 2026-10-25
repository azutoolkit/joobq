# JoobQ

<div align="center">

![JoobQ Logo](./joobq-logo.png)

[![Crystal CI](https://github.com/azutoolkit/joobq/actions/workflows/crystal.yml/badge.svg?branch=master)](https://github.com/azutoolkit/joobq/actions/workflows/crystal.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**A high-performance, production-ready asynchronous job queue system for Crystal**

[Features](#key-features) • [Installation](#installation) • [Quick Start](#getting-started) • [Documentation](#table-of-contents) • [API Reference](#rest-api--openapi-specification)

</div>

---

## Overview

**JoobQ** is an enterprise-grade asynchronous job queue system built for the Crystal programming language. Designed for both simplicity and scalability, JoobQ provides a robust framework for managing background job processing in applications of any size—from startup MVPs to large-scale distributed systems.

### Why Choose JoobQ?

JoobQ combines the performance advantages of Crystal with the reliability of Redis to deliver a job queue system that doesn't compromise on speed, reliability, or developer experience.

**Performance**

- Processes up to 35,000 jobs per second on modern hardware
- Built on Crystal's efficient concurrency model
- Optimized Redis operations for minimal latency

**Reliability**

- Automatic retry mechanisms with exponential backoff
- Dead letter queue for failed job analysis
- Job expiration and timeout handling
- Graceful shutdown preventing job loss

**Developer Experience**

- Clean, intuitive API following Crystal idioms
- Comprehensive OpenAPI 3.0 specification
- Type-safe job definitions
- Minimal configuration required

**Flexibility**

- Priority-based queue processing
- Cron-like recurring job scheduling
- Dynamic throttling and rate limiting
- Middleware support for cross-cutting concerns

### Key Features

- **🚀 High Performance**: Process tens of thousands of jobs per second with Crystal's native performance
- **⚡ Priority Queues**: Configure worker allocation based on queue priority
- **🔄 Retry Logic**: Built-in exponential backoff and customizable retry strategies
- **⏰ Scheduling**: Cron-style recurring jobs and delayed execution
- **🎯 Throttling**: Fine-grained rate limiting to prevent system overload
- **📊 Monitoring**: Comprehensive REST API for metrics and job management
- **🔌 OpenAPI Integration**: Complete API specification for client generation
- **🛡️ Error Tracking**: Detailed error monitoring and reporting
- **♻️ Dead Letter Queue**: Automatic handling of failed jobs
- **🔒 Type Safety**: Compile-time guarantees for job definitions

### Table of Contents

- [JoobQ](#joobq)
  - [Overview](#overview)
    - [Why Choose JoobQ?](#why-choose-joobq)
    - [Key Features](#key-features)
    - [Table of Contents](#table-of-contents)
  - [Getting Started](#getting-started)
    - [Prerequisites](#prerequisites)
    - [Quick Installation](#quick-installation)
  - [Installation](#installation)
  - [Usage](#usage)
    - [Environment Variables](#environment-variables)
    - [Configuration](#configuration)
    - [Configuration Properties](#configuration-properties)
    - [Example Configuration with All Properties](#example-configuration-with-all-properties)
    - [Defining Queues](#defining-queues)
    - [Queue Throttling](#queue-throttling)
      - [Queue Throttle Limit Property](#queue-throttle-limit-property)
      - [How They Work Together](#how-they-work-together)
      - [Summary](#summary)
    - [Defining Jobs](#defining-jobs)
      - [Best Practices for Defining Jobs](#best-practices-for-defining-jobs)
    - [Encrypting Job Arguments](#encrypting-job-arguments)
        - [Idempotency](#idempotency)
        - [Simple Primitive Types for Arguments](#simple-primitive-types-for-arguments)
        - [Number of Arguments](#number-of-arguments)
  - [JoobQ HTTP Server](#joobq-http-server)
    - [Rest API](#rest-api)
    - [GET /joobq/jobs/registry](#get-joobqjobsregistry)
    - [POST /joobq/jobs](#post-joobqjobs)
  - [REST API \& OpenAPI Specification](#rest-api--openapi-specification)
    - [API Endpoints](#api-endpoints)
    - [OpenAPI Specification](#openapi-specification)
    - [Quick Start with the API](#quick-start-with-the-api)
    - [Client Generation](#client-generation)
    - [Interactive Documentation](#interactive-documentation)
  - [Performance](#performance)
    - [Performance Comparison](#performance-comparison)
      - [Disclaimer](#disclaimer)
  - [Contributing](#contributing)
  - [Testing](#testing)
  - [Deployment](#deployment)
  - [License](#license)
  - [Acknowledgments](#acknowledgments)

## Getting Started

### Prerequisites

Before you begin, ensure you have the following installed:

- **Crystal** (version 0.34.0 or higher)
- **Redis** (version 5.0 or higher recommended)

### Quick Installation

1. **Clone the repository** (for development):

   ```bash
   git clone https://github.com/azutoolkit/joobq.git
   cd joobq
   ```

2. **Install dependencies**:

   ```bash
   shards install
   ```

3. **Start Redis** (if not already running):

   ```bash
   redis-server
   ```

## Installation

Add the following to your `shard.yml`:

```yaml
dependencies:
  joobq:
    github: azutoolkit/joobq
```

Then run:

```crystal
shards install
```

## Usage

```crystal
require "joobq"
```

### Environment Variables

```crystal
REDIS_HOST=localhost
REDIS_PORT=6379
REDIS_POOL_SIZE=500
REDIS_POOL_TIMEOUT=5.0
REDIS_PASS=somepass
REDIS_URL=rediss://user:password@redis.example.com:6380/0 # see "Connecting with a URL"
REDIS_TIMEOUT=0.2
JOOBQ_EVENTS_MAX_BYTES=67108864
JOOBQ_PAYLOAD_KEYS=2026a:<64 hex digits>,2025:<64 hex digits> # see "Encrypting Job Arguments"
```

`JOOBQ_EVENTS_MAX_BYTES` is the most memory the `joobq:events` stream may use (0 turns the limit off). The stream is also capped at about 50 000 entries. The byte limit is enforced from the worker heartbeat (every 10 s, at most one process checks per 10 s), so it is approximate: the stream can overshoot between beats, and it is trimmed to 90 % of the limit, never below 100 entries.

### Connecting with a URL

`REDIS_URL` (or `redis.url` in the YAML file) names the server in one value: `redis://[user:password@]host[:port][/database]`, `rediss://` for TLS, or `unix:///path/to/redis.sock[?db=N]`. A user name selects a Redis 6+ ACL user (`AUTH user password`; the `redis` shard alone only authenticates the default user), a password alone is the default user's, and the path is the database. Percent-encode `@ / : ? # %` inside the user name or password; a literal `+` stays a `+`. A query or fragment is refused (a credential put there would otherwise be ignored), except `db` on a unix URL.

`REDIS_URL` is used as it is, by the YAML loader and by the default store alike: `REDIS_HOST`, `REDIS_PORT` and `REDIS_PASS` do not change it, and it wins over `redis.url`. A URL that cannot be used stops start-up with a message that does not repeat it; JoobQ never falls back to a plain connection to `REDIS_HOST` because of a bad URL.

For `rediss://` the server certificate must be signed by a certificate authority JoobQ trusts (the system's, plus the PEM file in `REDIS_CA_FILE` / `redis.ca_file` if given: the file adds to the system's authorities, it does not replace them) and must be issued for the host in the URL. A certificate any trusted authority issued for another host is refused. `REDIS_TLS_VERIFY=false` (`redis.tls_verify: false`) turns both checks off; any value other than true/false/1/0/yes/no/on/off is an error. SSLv3 and TLS 1.0/1.1 are refused. The `redis` shard sends no server name (SNI), so a server that chooses its certificate by name needs a default one. For a store made from a URL the password never appears in logs, error messages or `inspect`/`pp`, and a connection that fails to authenticate is closed, never used as the default user. (A store made with `host:`, `port:` and `password:` is unchanged, and its connections still print the password when inspected.) When several YAML files are merged, the `redis` section of the last one that has one wins. A host written with a trailing dot or an IPv6 literal in brackets is accepted.

In code: `JoobQ::RedisStore.new(url: "rediss://...", ca_file: "ca.pem")`; `store.close` ends its connections (a store made with `host:` and `port:` keeps its pool open).

### Configuration

JoobQ can be configured using the `JoobQ.configure` method. Here is an example configuration:

```crystal
JoobQ.configure do
  queue "default", 10, EmailJob

  scheduler do
    cron("*/1 * * * *") { # Do Something }
    every 1.hour, EmailJob, email_address: "john.doe@example.com"
  end
end
```

### Configuration Properties

The `JoobQ::Configure` struct provides several properties that can be customized to configure the JoobQ system:

- `default_queue`: The name of the default queue. Defaults to `"default"`.
- `retries`: The number of retries for a job. Defaults to `3`.
- `expires`: The expiration time for a job. Defaults to `3.days`.
- `timeout`: The maximum execution time allowed for a job. Defaults to `2.seconds`.
- `failed_ttl`: The time-to-live for failed jobs. Defaults to `3.milliseconds`.
- `dead_letter_ttl`: The time-to-live for jobs in the dead letter queue. Defaults to `7.days`.
- `job_registry`: An instance of `JobSchemaRegistry` for managing job schemas.
- `store`: The store instance used for job storage and retrieval. Defaults to `RedisStore`.

### Example Configuration with All Properties

```crystal
JoobQ.configure do |config|
  config.default_queue = "default"
  config.retries = 5
  config.expires = 2.days
  config.timeout = 5.seconds
  config.failed_ttl = 1.minute
  config.dead_letter_ttl = 14.days

  queue "default", 10, EmailJob
  queue "priority", 5, PriorityJob, throttle: { limit: 100, period: 1.minute }

  scheduler do
    cron("*/1 * * * *") { # Do Something }
    every 1.hour, EmailJob, email_address: "john.doe@example.com"
  end
end
```

### Shutting Down

**Changed:** `JoobQ.forge` now traps `SIGTERM`, `SIGINT` and `SIGHUP` by default, replacing any handler your
application installed for them earlier (use `trap_signals: false` to keep yours).

`JoobQ.forge` traps `SIGTERM`, `SIGINT` and `SIGHUP` (`Process.on_terminate` covers all three): it calls
`JoobQ.shutdown` and then exits the process. **With the trap installed `forge` never returns**, and code after the
call does not run.

| Exit status | Meaning |
|---|---|
| 0 | clean shutdown: every job finished |
| 3 | the deadline passed with jobs still running; they were returned to their queues |
| 1 | a second signal, more than a second after the first, ended the shutdown early |

Pass `trap_signals: false` (or set `JOOBQ_TRAP_SIGNALS=0`) when your application installs its own handlers and
calls `JoobQ.shutdown` itself; `forge` then returns once the shutdown has finished.

```crystal
JoobQ.forge(trap_signals: false, shutdown_timeout: 20.seconds)
# elsewhere, in your own handler:
JoobQ.shutdown(20.seconds)
```

`JoobQ.shutdown(timeout = JoobQ::SHUTDOWN_TIMEOUT)` (15 seconds) stops, in order and within `timeout` in total: the
REST API started by `forge`, the schedulers (cron, recurring, delayed, the reaper) and the workers of every queue. It
then waits for the jobs that are running, and at the deadline (one second before `timeout`, which is kept for what
follows) it puts every job that is still running, and every job that was claimed but had not started, back at the end
of its queue, one atomic step per job, and flushes the latency counters. `JoobQ.abandoned_jobs` says how many it had
to put back. It is safe to call more than once and from any fiber: the first call does the work and returns `true`,
later calls (also while the first runs) wait for it and return `false`. After a shutdown the queues of the process
cannot be started again.

A job that is put back keeps executing in the old process until it ends (a fiber cannot be killed), and may finish
its own side effects inside `perform`. What JoobQ does for that execution is switched off: it is not retried,
dead-lettered, counted, announced or removed from the processing list, so the requeued copy is the only one JoobQ
schedules. Workers claim nothing once the shutdown has begun.

Jobs put back run again from the start, possibly in another process while this one winds down, so they must be safe to
run twice, as they must be after a crash. A process that is killed (`SIGKILL`) cannot do this; its jobs stay in the
queue's processing list. Start-up recovery (`Queue#start`) moves at most **one** job per queue from that list back to
the queue, and it takes jobs of any process serving the queue: a process that starts while another one is working on
the same queue can move that process's running job back, so it runs twice. Prefer a graceful stop (`SIGTERM`) in
rolling deploys.

### Defining Queues

Queues are of type Hash(String, Queue(T)) where the name of the key matches the name of the Queue.

**Example:**

```crystal
JoobQ.configure do
  queue name: "single", workers: 10, job: Job1, throttle: { limit: 20, period: 1.minute }
  queue "example", 10, ExampleJob | FailJob

  # Scheduling Recurring Jobs
  scheduler do
    cron("*/1 * * * *") { # Do Something }
    cron("*/5 20-23 * * *") { # Do Something }
    every 1.hour, ExampleJob, x: 1
  end
end
```

### Queue Throttling

The worker throttle mechanism in JoobQ works in conjunction with the Queue Throttle Limit property to manage the rate at
which jobs are processed. Here's how it works:

#### Queue Throttle Limit Property

The Queue Throttle limit property sets a maximum number of jobs that can be processed within a specific time frame. This
helps to control the load on the system and ensures that the job processing rate does not exceed a certain threshold.

#### How They Work Together

- **Job Availability and Throttle Limit:** The worker checks the queue for available jobs. If the number of jobs processed
  within the specified time frame reaches the throttle limit, the worker will wait until it is allowed to process more
  jobs. This prevents the system from being overwhelmed by too many jobs at once.

- **Job Expiration:** Before processing a job, the worker checks if the job has expired. If the job has expired, it is
  marked as expired and not processed. This ensures that only valid jobs are processed, reducing unnecessary work.

- **Controlled Shutdown:** The worker can be stopped gracefully by sending a termination signal. This allows for a
  controlled shutdown, ensuring that no jobs are abruptly terminated.

**Example:**

Here is an example of how you might configure the Queue Throttle limit property:

```crystal
JoobQ.configure do
  queue "default", 10, EmailJob, throttle: { limit: 100, period: 60.seconds }
end
```

In this example, the throttle limit is set to 100 jobs per 60 seconds. This means that the worker will process up to 100
jobs every 60 seconds. If the limit is reached, the worker will wait until the next period to continue processing jobs.

#### Summary

The worker throttle mechanism, combined with the Queue Throttle limit property, ensures that job processing is controlled
and efficient. By managing job availability, expiration, and processing rate, JoobQ provides a robust system for
handling job queues without overwhelming the system.

### Defining Jobs

To define Jobs, include the JoobQ::Job module, and implement the perform method.

```crystal
struct EmailJob
  include JoobQ::Job

  # Name of the queue to be processed by
  @queue   = "default"
  # Number Of Retries for this job
  @retries = 0
  # Job Expiration
  @expires = 1.days.total_seconds.to_i

  # Initialize as normal with or without named tuple arguments
  def initialize(@email_address : String)
  end

  def perform
    # Logic to handle job execution
  end
end
```

**Executing Job:**

```crystal
# Enqueue the job (Async)
EmailJob.enqueue(email_address: "john.doe@example.com")

# Batch enqueue jobs
EmailJob.batch_enqueue([job1, job2, job3])

# Perform Immediately
EmailJob.new(email_address: "john.doe@example.com").perform

# Delayed
EmailJob.delay(for: 1.hour, email_address: "john.doe@example.com")
EmailJob.enqueue_at(time: 3.minutes.from_now, email_address: "john.doe@example.com")

# Recurring at given interval
EmailJob.schedule(every: 1.second, email_address: "john.doe@example.com")
```

#### Best Practices for Defining Jobs

When defining jobs in JoobQ, it's important to follow certain best practices to ensure reliability and maintainability. Here are some key recommendations:

##### Idempotency

Jobs must be idempotent. This means that running the same job multiple times should produce the same result. Idempotency is crucial for ensuring that jobs can be retried safely without causing unintended side effects. To achieve idempotency:

- Avoid modifying external state directly within the job.
- Use unique identifiers to track job execution and prevent duplicate processing.
- Ensure that any side effects (e.g., database updates, API calls) are safe to repeat.

##### Simple Primitive Types for Arguments

Job arguments must be simple primitive types such as integers, strings, and booleans. This ensures that the job data can be easily serialized and deserialized, and reduces the risk of errors during job execution. Complex objects or data structures should be avoided as job arguments.

##### Number of Arguments

Keep the number of arguments for jobs to a minimum. Having too many arguments can make the job definition complex and harder to maintain. As a best practice:

- Limit the number of arguments to 3-5.
- Group related arguments into a single object if necessary.
- Use default values for optional arguments to simplify job invocation.

By following these best practices, you can ensure that your jobs are reliable, maintainable, and easy to work with in the JoobQ framework.

### Encrypting Job Arguments

A job is stored as JSON in Redis (queue, processing list, retry and scheduled sets, dead letters), readable by anyone with access to Redis or a backup. Declare the sensitive properties with `encrypted_property` and they are written as AES-256-GCM sealed strings and opened again when the worker loads the job, before `perform` runs. Jobs that do not use it pay nothing.

```crystal
class ChargeJob
  include JoobQ::Job

  property order_id : Int64 = 0 # stays readable
  encrypted_property card_token : String = ""
  encrypted_property billing : Hash(String, String)? = nil

  def perform
    charge(card_token) # plain text here
  end
end
```

Keys: one is *current* and seals; older ones only open. A key is `id:key` (32 bytes as 64 hex digits or base64; the id is 1 to 16 of `a-z 0-9 _ -`, `default` when omitted).

```crystal
JoobQ.configure do
  payload_encryption current: "2026a:#{ENV["NEW_KEY"]}", previous: ["2025:#{ENV["OLD_KEY"]}"]
end
```

Without that call the keys come from `JOOBQ_PAYLOAD_KEYS` (comma separated `id:key`, first is current) or `JOOBQ_PAYLOAD_KEY` (one key). To rotate, put the new key first and keep the old one until no job sealed with it can still be in Redis; a retried job is rewritten with the current key.

- Each value carries its key id, a random 96 bit nonce and the tag. The job class and the property name are authenticated data, so a value copied to another field or class is refused. Renaming the class or the property makes stored values unreadable; pass `job_name:` to `encrypted_property` to pin the name.
- A job whose values cannot be opened because of the *job* (unknown key id, wrong class or field, altered, damaged) is never run: it goes to the dead-letter set as the job itself with error type `decryption_error` and a message that names the class and property but holds no value. Once the key is back, redrive it (dead-letter API or `DeadLetterQueue#redrive`) and it runs.
- A problem with the *process's keys* (none configured, `JOOBQ_PAYLOAD_KEYS` malformed) is a configuration error: the queue of a job class with encrypted properties refuses to start, enqueuing raises `JoobQ::Encryption::Error`, and a worker that meets such a job puts it back on its queue (atomically, not counted as processed) and stops claiming for a few seconds (`Encryption.key_backoff`, monotonic clock) instead of dead-lettering it.
- Values written before the property was encrypted are read as they are and sealed on the next write. Set `JoobQ.config.allow_plaintext_payloads = false` to make workers refuse them (the job is dead-lettered without its payload, which holds the plain values: that legacy job is gone, so drain old jobs first rather than flipping the flag). The same withholding applies to any other parse error in a job class with encrypted properties (`Queue#add` and the HTTP API still accept plain values, which are then sealed). While it is true, anyone who can write to Redis can substitute an unsealed value and it will run.
- The library scrubs the plain values (and their `to_s`, `inspect`, JSON forms and the leaves of hashes and arrays; strings under 4 characters and numbers under 6 digits excepted, booleans never) from the error messages, causes and backtraces it records (error context, `job.failed` event, stored job error). It cannot scrub what your own `perform` logs. Scrubbing never raises: if it cannot be done the text is replaced by `[REDACTED: not scrubbable]`, so the job still retries or dead-letters.
- The sealed value is bound to the class and property, not to the job id: someone who can write to Redis can copy a sealed value between jobs of the same class and property. Nonces are random 96 bit values: rotate keys before about 2^32 seals per key.
- Sealing is not deterministic (random nonce per value): two serialisations of one job differ, so nothing may re-serialise a job to find it again by value.
- Properties are sealed only in the stored payload: in memory, and in your own logs, they are plain. `String` values are sealed as they are, other types as their JSON text. The size of a value is not hidden.

## JoobQ HTTP Server

The `APIServer` class provides a REST API to interact with the JoobQ job queue system. It listens for HTTP requests and handles job enqueuing, job registry retrieval, and queue metrics.

To start the API server.

```crystal
APIServer.start
```

### Rest API

JoobQ provides a REST API to interact with the job queue. Below are the available endpoints:

### GET /joobq/jobs/registry

This endpoint returns all available registered jobs and their JSON schemas that can be enqueued via the REST API.

**Request:**

```http
GET /joobq/jobs/registry HTTP/1.1
Host: localhost:8080
```

**Response:**

```json
{
  "EmailJob": {
    "type": "object",
    "properties": {
      "email_address": {
        "type": "string"
      }
    },
    "required": ["email_address"]
  }
}
```

### POST /joobq/jobs

This endpoint allows users to enqueue jobs.

**Request:**

```http
POST /joobq/jobs HTTP/1.1
Host: localhost:8080
Content-Type: application/json
Content-Length: 175

{
    "jid": "a13324f4-bdd8-4cf5-b566-c0c9c312f68b",
    "queue": "queue:test",
    "retries": 3,
    "expires": {{timestamp_plus_30}},
    "status": "enqueued",
    // Job initialization arguments
    "x": 10
}
```

**Response:**

```json
{
  "status": "Job enqueued",
  "queue": "default",
  "job_id": "some-unique-job-id"
}
```

## REST API & OpenAPI Specification

JoobQ provides a comprehensive REST API for job management, monitoring, and debugging. The API is fully documented with an OpenAPI 3.0 specification that enables easy client generation and integration.

### API Endpoints

- **Job Management**: Enqueue jobs, retrieve job registry
- **Queue Operations**: Reprocess busy jobs, monitor queue health
- **Error Monitoring**: Track errors, get statistics, filter by type/queue
- **Health Checks**: System status and monitoring

### OpenAPI Specification

The complete OpenAPI 3.0 specification is available in the `docs/` directory:

- **Specification**: `docs/openapi.yaml`
- **Documentation**: `docs/API_SPECIFICATION.md`
- **Client Examples**: `examples/crystal_client_example.cr`

### Quick Start with the API

```bash
# Health check
curl http://localhost:8080/joobq/health/check

# Enqueue a job
curl -X POST http://localhost:8080/joobq/jobs \
  -H "Content-Type: application/json" \
  -d '{
    "queue": "email",
    "job_type": "EmailJob",
    "data": {
      "email": "user@example.com",
      "subject": "Welcome"
    }
  }'

# Get error statistics
curl http://localhost:8080/joobq/errors/stats

# Reprocess busy jobs
curl -X POST http://localhost:8080/joobq/queues/default/reprocess
```

### Client Generation

Generate clients for your preferred language:

```bash
# Install OpenAPI Generator
brew install openapi-generator

# Generate clients
openapi-generator generate -i docs/openapi.yaml -g crystal -o clients/crystal/
openapi-generator generate -i docs/openapi.yaml -g typescript-axios -o clients/typescript/
openapi-generator generate -i docs/openapi.yaml -g python -o clients/python/
```

### Interactive Documentation

View the interactive API documentation:

```bash
docker run -p 8080:8080 -e SWAGGER_JSON=/docs/openapi.yaml -v $(pwd)/docs:/docs swaggerapi/swagger-ui
```

## Performance

JoobQ is designed for high performance and scalability. In our benchmarks, JoobQ has easily achieved processing rates of 35,000 jobs per second. This performance is made possible by leveraging Crystal's concurrency model and efficient job handling mechanisms.

### Performance Comparison

To provide a clearer picture of JoobQ's performance, we have compared it with other popular job queue processing tools
in various programming languages, including Sidekiq (Ruby), Celery (Python), Laravel Queue (PHP), and Quartz (Java).
The results are summarized in the table below:

| Job Queue Tool | Language | Jobs per Second |
| -------------- | -------- | --------------- |
| JoobQ          | Crystal  | 35,000          |
| Sidekiq        | Ruby     | 23,500          |
| Celery         | Python   | 15,000          |
| Laravel Queue  | PHP      | 10,000          |
| Quartz         | Java     | 25,000          |

JoobQ Hardware benchmarks performed

```info
Hardware Overview:
  Model Name:             MacBook Pro
  Model Identifier:       Mac15,10
  Model Number:           MRX53LL/A
  Chip:                   Apple M3 Max
  Total Number of Cores: 14 (10 performance and 4 efficiency)
  Memory:                 36 GB
```

As shown in the table, JoobQ outperforms many of the popular job queue processing tools, making it an excellent
choice for high-throughput job processing needs.

#### Disclaimer

JoobQ out of the box provides great performance, achieving processing rates of up to 35,000 jobs per second in our
benchmarks. However, it's important to note that with the right environment and settings, any job scheduler can be
performant. Factors such as hardware specifications, network conditions, and job complexity can significantly impact
the performance of job queue processing tools. Therefore, it's essential to optimize your environment and configurations
to achieve the best possible performance for your specific use case.

## Contributing

1. Fork it (<https://github.com/azutoolkit/joobq/fork>)
2. Create your feature branch (git checkout -b my-new-feature)
3. Commit your changes (git commit -am 'Add some feature')
4. Push to the branch (git push origin my-new-feature)
5. Create a new Pull Request

## Testing

To run the tests, use the following command:

```bash
crystal spec
```

## Deployment

To deploy JoobQ, ensure that you have a running Redis instance. You can use the provided docker-compose.yml to set
up Redis.

```bash
docker-compose up -d
```

## License

The MIT License (MIT). Please see License File for more information.

## Acknowledgments

[Elias J. Perez](https://github.com/eliasjpr/) - creator and maintainer
[Crystal Language](https://crystal-lang.org/)
[Redis](https://redis.io/)
