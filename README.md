# JoobQ

![JoobQ Logo](./joobq-logo.png)

[![Crystal CI](https://github.com/azutoolkit/joobq/actions/workflows/crystal.yml/badge.svg)](https://github.com/azutoolkit/joobq/actions/workflows/crystal.yml)

## Overview

Welcome to **JoobQ** – is a great solution for fast, efficient, and reliable asynchronous job queue scheduling! Whether you're building a small application or a large-scale system, JoobQ is designed to handle your job processing needs with ease and precision.

### Why JoobQ?

JoobQ is more than just a job queue scheduler; it's a robust framework that ensures your jobs are managed and executed seamlessly. Here's why developers love JoobQ:

- **Blazing Fast Performance**: JoobQ leverages the power of Crystal language and Redis to deliver lightning-fast job processing.
- **Reliability**: With built-in retry mechanisms, dead letter queues, and job expiration handling, JoobQ ensures that no job is left behind.
- **Flexibility**: Configure your job queues, set custom retry policies, and schedule jobs with cron-like syntax – all with minimal effort.
- **Scalability**: JoobQ is designed to scale with your application, handling millions of jobs effortlessly.
- **Developer Friendly**: With a clean and intuitive API, JoobQ makes it easy for developers to define, enqueue, and manage jobs.

### Key Features

- **Priority Queues**: Assign different priorities to your job queues based on the number of workers.
- **Error Handling**: Robust error handling with detailed logging and retry mechanisms.
- **Cron-like Scheduling**: Schedule recurring jobs with cron syntax.
- **Delayed Jobs**: Delay job execution to a specific time in the future.
- **Throttle Control**: Manage the rate at which jobs are processed to prevent system overload.
- **REST API**: Interact with JoobQ through a comprehensive REST API for job management and metrics.
- **Graceful Termination**: Stop workers gracefully without losing jobs in progress.

### Get Started!

Ready to dive in? Follow our [Getting Started](#getting-started) guide to set up JoobQ in your project and start processing jobs like a pro!

### Table of Contents

- [JoobQ](#joobq)
  - [Overview](#overview)
    - [Why JoobQ?](#why-joobq)
    - [Key Features](#key-features)
    - [Get Started!](#get-started)
    - [Table of Contents](#table-of-contents)
  - [Getting Started](#getting-started)
    - [Prerequisites](#prerequisites)
    - [Setting Up](#setting-up)
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
    - [GET /joob/metrics](#get-joobmetrics)
  - [Performance](#performance)
    - [Performance Comparison](#performance-comparison)
      - [Disclaimer](#disclaimer)
  - [Contributing](#contributing)
  - [Testing](#testing)
  - [Deployment](#deployment)
  - [Roadmap](#roadmap)
  - [License](#license)
  - [Acknowledgments](#acknowledgments)

## Getting Started

This section will help you get started with JoobQ. Follow the instructions below to set up and run the project.

### Prerequisites

- Crystal language (>= 0.34.0)
- Redis

### Setting Up

1. Clone the repository:

   ```sh
   git clone https://github.com/azutoolkit/joobq.git
   cd joobq
   ```

2. Install dependencies:

   ```sh
   shards install
   ```

3. Start Redis with TimeSeries module:

   ```sh
   docker-compose up -d
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
REDIS_POOL_SIZE=50
REDIS_PASS=somepass
REDIS_TIMEOUT=0.2
```

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

### GET /joob/metrics

This endpoint returns metrics about the queue

**Rquest:**

```http
GET /joobq/metrics HTTP/1.1
Host: localhost:8080
```

**Response:**

```json
[
  {
    "queue:test": {
      "total_workers": 5,
      "status": "Running",
      "metrics": {
        "enqueued": 394775,
        "completed": 171446,
        "retried": 1757,
        "dead": 0,
        "processing": 3,
        "running_workers": 5,
        "jobs_per_second": 24624.079804538018,
        "errors_per_second": 252.17920194481889,
        "enqueued_per_second": 56652.61565975511,
        "jobs_latency": "00:00:00.000040613",
        "elapsed_time": "00:00:06.970125250"
      }
    }
  }
]
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
  Model Name:	MacBook Pro
  Model Identifier:	Mac15,10
  Model Number:	MRX53LL/A
  Chip:	Apple M3 Max
  Total Number of Cores:	14 (10 performance and 4 efficiency)
  Memory:	36 GB
  System Firmware Version:	10151.140.19
  OS Loader Version:	10151.140.19
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

## Roadmap

- [ ] CLI to manage queues and monitor server
- [ ] Extend the REST API for more functionality
- [ ] Approve Queue: Jobs have to be manually approved to execute

## License

The MIT License (MIT). Please see License File for more information.

## Acknowledgments

Elias J. Perez - creator and maintainer
Crystal Language
Redis
