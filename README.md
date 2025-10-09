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

Add JoobQ to your project's `shard.yml`:

```yaml
dependencies:
  joobq:
    github: azutoolkit/joobq
```

Install dependencies:

```bash
shards install
```

## Usage

### Basic Setup

Require JoobQ in your application:

```crystal
require "joobq"
```

### Environment Variables

Configure Redis connection using environment variables:

```bash
REDIS_HOST=localhost           # Redis server host
REDIS_PORT=6379                # Redis server port
REDIS_POOL_SIZE=500            # Connection pool size
REDIS_POOL_TIMEOUT=5.0         # Pool checkout timeout (seconds)
REDIS_PASS=your_password       # Redis authentication password
REDIS_TIMEOUT=0.2              # Command timeout (seconds)
```

### Configuration

JoobQ uses a declarative configuration API. Configure your queues, jobs, and schedulers in a single block:

```crystal
JoobQ.configure do
  queue "default", 10, EmailJob

  scheduler do
    cron("*/1 * * * *") { puts "Running scheduled task" }
    every 1.hour, EmailJob, email_address: "admin@example.com"
  end
end
```

### Configuration Properties

The `JoobQ::Configure` struct provides comprehensive customization options:

| Property          | Type                | Default          | Description                              |
| ----------------- | ------------------- | ---------------- | ---------------------------------------- |
| `default_queue`   | `String`            | `"default"`      | Default queue name for jobs              |
| `retries`         | `Int32`             | `3`              | Number of retry attempts for failed jobs |
| `expires`         | `Time::Span`        | `3.days`         | Job expiration time                      |
| `timeout`         | `Time::Span`        | `2.seconds`      | Maximum job execution time               |
| `failed_ttl`      | `Time::Span`        | `3.milliseconds` | TTL for failed jobs                      |
| `dead_letter_ttl` | `Time::Span`        | `7.days`         | TTL for dead letter queue jobs           |
| `job_registry`    | `JobSchemaRegistry` | Auto             | Job schema registry instance             |
| `store`           | `Store`             | `RedisStore`     | Storage backend for job persistence      |

### Complete Configuration Example

```crystal
JoobQ.configure do |config|
  # Global settings
  config.default_queue = "default"
  config.retries = 5
  config.expires = 2.days
  config.timeout = 5.seconds
  config.failed_ttl = 1.minute
  config.dead_letter_ttl = 14.days

  # Define queues with worker allocation
  queue "default", 10, EmailJob
  queue "priority", 5, PriorityJob, throttle: { limit: 100, period: 1.minute }

  # Schedule recurring jobs
  scheduler do
    cron("*/1 * * * *") { puts "Heartbeat check" }
    every 1.hour, EmailJob, email_address: "admin@example.com"
  end
end
```

### Defining Queues

Queues in JoobQ are strongly typed collections that map queue names to their respective job types. Each queue is configured with a specific number of worker processes to handle job execution.

**Queue Definition Syntax:**

```crystal
queue name : String, workers : Int32, job_types : JobType, throttle : NamedTuple?
```

**Examples:**

```crystal
JoobQ.configure do
  # Single job type queue with throttling
  queue "emails", 10, EmailJob, throttle: { limit: 20, period: 1.minute }

  # Multiple job types using union types
  queue "processing", 10, ExampleJob | FailJob

  # High-priority queue with more workers
  queue "critical", 50, CriticalJob

  # Schedule recurring jobs
  scheduler do
    cron("*/1 * * * *") { puts "Minute task" }
    cron("*/5 20-23 * * *") { puts "Evening task" }
    every 1.hour, ExampleJob, x: 1
  end
end
```

### Queue Throttling

JoobQ provides sophisticated rate limiting to prevent system overload and ensure controlled job processing. The throttling mechanism operates at the queue level, allowing you to define precise limits for different types of workloads.

#### Throttle Configuration

Throttling is configured using a `NamedTuple` with two properties:

- **`limit`**: Maximum number of jobs to process within the time period
- **`period`**: Time window for the limit (using Crystal's `Time::Span`)

#### Throttling Behavior

**Rate Limiting**

- Workers monitor job processing rates in real-time
- When the limit is reached, workers pause until the next period begins
- Prevents downstream service overload and API rate limit violations

**Job Expiration**

- Workers automatically check job expiration before processing
- Expired jobs are marked and moved to the dead letter queue
- Prevents wasted resources on stale operations

**Graceful Degradation**

- Workers can be stopped gracefully without job loss
- In-flight jobs complete before shutdown
- Unprocessed jobs remain in the queue for the next worker

#### Throttling Example

```crystal
JoobQ.configure do
  # Limit to 100 emails per minute
  queue "emails", 10, EmailJob, throttle: { limit: 100, period: 1.minute }

  # API calls limited to 1000 per hour
  queue "api_calls", 5, APIJob, throttle: { limit: 1000, period: 1.hour }

  # High-throughput queue with no throttling
  queue "analytics", 20, AnalyticsJob
end
```

#### Best Practices

- Set throttle limits based on downstream service capacity
- Monitor queue depth to ensure throttling isn't too aggressive
- Use separate queues for different rate limit requirements
- Consider peak load scenarios when setting limits

### Defining Jobs

Jobs in JoobQ are Crystal structs that include the `JoobQ::Job` module. Each job must implement a `perform` method containing the business logic to execute.

#### Job Structure

```crystal
struct EmailJob
  include JoobQ::Job

  # Queue assignment
  @queue = "default"

  # Retry configuration
  @retries = 3

  # Job expiration (in seconds)
  @expires = 1.day.total_seconds.to_i

  # Type-safe initialization
  def initialize(@email_address : String)
  end

  # Business logic implementation
  def perform
    # Send email logic here
    puts "Sending email to #{@email_address}"
  end
end
```

#### Job Execution Methods

JoobQ provides multiple ways to execute jobs based on your timing requirements:

**Immediate Execution**

```crystal
# Asynchronous (enqueue for background processing)
EmailJob.enqueue(email_address: "user@example.com")

# Synchronous (execute immediately in current context)
EmailJob.new(email_address: "user@example.com").perform
```

**Batch Operations**

```crystal
# Enqueue multiple jobs atomically
jobs = [
  EmailJob.new(email_address: "user1@example.com"),
  EmailJob.new(email_address: "user2@example.com"),
  EmailJob.new(email_address: "user3@example.com")
]
EmailJob.batch_enqueue(jobs)
```

**Delayed Execution**

```crystal
# Delay by duration
EmailJob.delay(for: 1.hour, email_address: "user@example.com")

# Schedule for specific time
EmailJob.enqueue_at(
  time: 3.minutes.from_now,
  email_address: "user@example.com"
)
```

**Recurring Jobs**

```crystal
# Execute at regular intervals
EmailJob.schedule(
  every: 1.hour,
  email_address: "admin@example.com"
)
```

#### Best Practices for Defining Jobs

Follow these guidelines to create robust, maintainable jobs that work reliably in production environments.

##### 1. Idempotency

**Jobs must be idempotent.** Running the same job multiple times should produce identical results without adverse side effects.

**Guidelines:**

- Design jobs to check for existing state before making changes
- Use unique identifiers to track job execution
- Implement conditional logic to handle duplicate processing
- Ensure database operations use upsert patterns where appropriate

**Example:**

```crystal
def perform
  return if already_processed?(@email_address)

  send_email(@email_address)
  mark_as_processed(@email_address)
end
```

##### 2. Use Simple Primitive Types

**Job arguments should be primitive types:** strings, integers, booleans, and floats. This ensures reliable serialization and deserialization.

**Recommended:**

```crystal
def initialize(@user_id : Int64, @email : String, @send_copy : Bool = false)
end
```

**Avoid:**

```crystal
# Don't pass complex objects
def initialize(@user : User, @config : Config)  # ❌
end
```

##### 3. Minimize Arguments

**Limit job arguments to 3-5 parameters** for better maintainability and readability.

**If you need more data:**

- Store related data in your database and pass only the ID
- Use a single reference identifier to fetch related data within the job
- Consider breaking the job into smaller, focused jobs

**Example:**

```crystal
# Good: Pass ID and fetch data in perform
struct UserNotificationJob
  def initialize(@user_id : Int64, @notification_type : String)
  end

  def perform
    user = User.find(@user_id)
    # Process notification
  end
end
```

##### 4. Error Handling

Implement proper error handling and logging within your jobs:

```crystal
def perform
  # Job logic
rescue ex : Exception
  Log.error { "Job failed: #{ex.message}" }
  raise ex  # Re-raise to trigger retry mechanism
end
```

## JoobQ HTTP Server

JoobQ includes a built-in HTTP server providing a RESTful API for job management, monitoring, and system introspection. The API enables external applications to interact with the job queue system programmatically.

### Starting the API Server

```crystal
require "joobq/api_server"

JoobQ::APIServer.start(host: "0.0.0.0", port: 8080)
```

### Core API Endpoints

#### GET /joobq/jobs/registry

Retrieve the complete registry of available job types with their JSON schemas. This endpoint is useful for API clients to understand job requirements and generate validation logic.

**Request:**

```http
GET /joobq/jobs/registry HTTP/1.1
Host: localhost:8080
Accept: application/json
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
  },
  "NotificationJob": {
    "type": "object",
    "properties": {
      "user_id": {
        "type": "integer"
      },
      "message": {
        "type": "string"
      }
    },
    "required": ["user_id", "message"]
  }
}
```

#### POST /joobq/jobs

Enqueue a new job for asynchronous processing.

**Request:**

```http
POST /joobq/jobs HTTP/1.1
Host: localhost:8080
Content-Type: application/json

{
  "jid": "a13324f4-bdd8-4cf5-b566-c0c9c312f68b",
  "queue": "default",
  "job_type": "EmailJob",
  "retries": 3,
  "expires": 1735689600,
  "status": "enqueued",
  "data": {
    "email_address": "user@example.com"
  }
}
```

**Response:**

```json
{
  "status": "success",
  "message": "Job enqueued successfully",
  "queue": "default",
  "job_id": "a13324f4-bdd8-4cf5-b566-c0c9c312f68b"
}
```

**Error Response:**

```json
{
  "status": "error",
  "message": "Invalid job parameters",
  "errors": ["email_address is required"]
}
```

## REST API & OpenAPI Specification

JoobQ provides a production-ready REST API with comprehensive OpenAPI 3.0 documentation. The API enables programmatic job management, real-time monitoring, and seamless integration with external systems.

### API Capabilities

| Category             | Features                                                |
| -------------------- | ------------------------------------------------------- |
| **Job Management**   | Enqueue jobs, retrieve registry, inspect job status     |
| **Queue Operations** | Reprocess jobs, monitor health, manage priorities       |
| **Error Monitoring** | Track errors, retrieve statistics, filter by type/queue |
| **Health Checks**    | System status, Redis connectivity, worker monitoring    |

### Documentation & Specification

The complete OpenAPI 3.0 specification provides all the details needed for integration:

| Resource              | Location                             |
| --------------------- | ------------------------------------ |
| **OpenAPI Spec**      | `docs/openapi.yaml`                  |
| **API Documentation** | `docs/API_SPECIFICATION.md`          |
| **Client Examples**   | `examples/crystal_client_example.cr` |

### API Examples

**Health Check**

```bash
curl http://localhost:8080/joobq/health/check
```

**Enqueue Job**

```bash
curl -X POST http://localhost:8080/joobq/jobs \
  -H "Content-Type: application/json" \
  -d '{
    "queue": "email",
    "job_type": "EmailJob",
    "data": {
      "email_address": "user@example.com"
    }
  }'
```

**Error Statistics**

```bash
curl http://localhost:8080/joobq/errors/stats
```

**Reprocess Busy Jobs**

```bash
curl -X POST http://localhost:8080/joobq/queues/default/reprocess
```

### Client Generation

Generate type-safe API clients using OpenAPI Generator:

```bash
# Install OpenAPI Generator
brew install openapi-generator

# Generate clients for various languages
openapi-generator generate -i docs/openapi.yaml -g crystal -o clients/crystal/
openapi-generator generate -i docs/openapi.yaml -g typescript-axios -o clients/typescript/
openapi-generator generate -i docs/openapi.yaml -g python -o clients/python/
openapi-generator generate -i docs/openapi.yaml -g go -o clients/go/
```

### Interactive Documentation

Launch Swagger UI for interactive API exploration:

```bash
docker run -p 8080:8080 \
  -e SWAGGER_JSON=/docs/openapi.yaml \
  -v $(pwd)/docs:/docs \
  swaggerapi/swagger-ui
```

Navigate to `http://localhost:8080` to explore the API interactively.

## Performance

JoobQ is architected for high-throughput job processing, leveraging Crystal's performance characteristics and efficient concurrency model. Benchmark results demonstrate sustained processing rates exceeding 35,000 jobs per second on modern hardware.

### Benchmark Results

Comparative analysis with established job queue systems across different language ecosystems:

| Framework     | Language    | Jobs/Second | Relative Performance |
| ------------- | ----------- | ----------- | -------------------- |
| **JoobQ**     | **Crystal** | **35,000**  | **Baseline**         |
| Sidekiq       | Ruby        | 23,500      | 67%                  |
| Quartz        | Java        | 25,000      | 71%                  |
| Celery        | Python      | 15,000      | 43%                  |
| Laravel Queue | PHP         | 10,000      | 29%                  |

### Test Environment

Benchmarks were conducted on the following hardware configuration:

```text
Hardware Specifications:
  Model:          MacBook Pro (2024)
  Identifier:     Mac15,10
  Processor:      Apple M3 Max
  CPU Cores:      14 (10 performance + 4 efficiency)
  Memory:         36 GB
  Storage:        SSD
  Redis Version:  7.0+
```

### Performance Characteristics

**Concurrency Model**

- Leverages Crystal's lightweight fibers for efficient concurrent processing
- Minimal memory overhead per job
- Non-blocking I/O operations

**Optimization Features**

- Redis pipelining for batch operations
- Connection pooling to minimize latency
- Efficient serialization/deserialization
- Zero-copy job passing where possible

### Important Considerations

**Performance is Environment-Dependent**

While JoobQ delivers exceptional out-of-the-box performance, actual throughput depends on multiple factors:

- **Hardware**: CPU cores, memory, and storage performance
- **Network**: Redis connection latency and bandwidth
- **Job Complexity**: Computation time and I/O operations within jobs
- **Configuration**: Worker count, connection pool size, and throttling settings
- **System Load**: Concurrent processes and resource availability

**Optimization Recommendations**

For production deployments:

1. Profile your specific job workloads
2. Tune worker counts based on job characteristics
3. Optimize Redis configuration for your use case
4. Monitor system metrics and adjust accordingly
5. Use throttling to prevent resource exhaustion

**Benchmark Methodology**

These benchmarks measure simple no-op jobs to evaluate framework overhead. Real-world performance will vary based on actual job complexity and system integration.

## Contributing

We welcome contributions from the community! JoobQ is open source and thrives on collaborative development.

### How to Contribute

1. **Fork the repository**
   Visit <https://github.com/azutoolkit/joobq/fork> and create your fork

2. **Create a feature branch**

   ```bash
   git checkout -b feature/your-feature-name
   ```

3. **Make your changes**

   - Write clear, idiomatic Crystal code
   - Add tests for new functionality
   - Update documentation as needed

4. **Commit your changes**

   ```bash
   git commit -am 'Add feature: description of your changes'
   ```

5. **Push to your fork**

   ```bash
   git push origin feature/your-feature-name
   ```

6. **Create a Pull Request**
   Open a PR against the `master` branch with a clear description of your changes

### Contribution Guidelines

- Follow Crystal style conventions
- Maintain test coverage above 80%
- Update relevant documentation
- Add examples for new features
- Ensure all tests pass before submitting

For more details, see [CONTRIBUTING.md](CONTRIBUTING.md).

## Testing

JoobQ includes a comprehensive test suite to ensure reliability and correctness.

### Running Tests

Execute the full test suite:

```bash
crystal spec
```

### Run specific test files:

```bash
crystal spec spec/queue_spec.cr
crystal spec spec/worker_spec.cr
```

### Watch mode for development:

```bash
watchexec -e cr crystal spec
```

## Deployment

### Production Requirements

- **Redis**: Version 5.0 or higher (6.0+ recommended)
- **Crystal**: Version 0.34.0 or higher
- **System Resources**: Allocate based on workload (see Performance section)

### Docker Deployment

JoobQ includes a Docker Compose configuration for easy deployment:

```bash
# Start Redis and supporting services
docker-compose up -d

# Verify services are running
docker-compose ps
```

### Configuration Management

For production environments:

1. Use environment variables for sensitive configuration
2. Implement health check endpoints
3. Configure monitoring and alerting
4. Set up log aggregation
5. Enable error tracking (e.g., Sentry integration)

### Scaling Considerations

- Run multiple worker processes for horizontal scaling
- Use Redis Sentinel or Cluster for high availability
- Monitor queue depth and adjust worker counts
- Implement circuit breakers for external service calls

## License

JoobQ is released under the MIT License. See the [LICENSE](LICENSE) file for full details.

## Acknowledgments

### Core Team

- **[Elias J. Perez](https://github.com/eliasjpr/)** - Creator and Maintainer

### Built With

- **[Crystal Language](https://crystal-lang.org/)** - High-performance, compiled language with Ruby-like syntax
- **[Redis](https://redis.io/)** - In-memory data structure store used for job persistence

### Community

Special thanks to all contributors who have helped improve JoobQ through bug reports, feature requests, and code contributions.

---

<div align="center">

**[Documentation](docs/DOCUMENTATION_INDEX.md)** • **[API Reference](docs/API_ENDPOINTS_REFERENCE.md)** • **[Issues](https://github.com/azutoolkit/joobq/issues)** • **[Discussions](https://github.com/azutoolkit/joobq/discussions)**

Made with ❤️ by the Crystal community

</div>
