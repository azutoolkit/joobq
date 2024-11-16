# JoobQ

![JoobQ Logo](./joobq-logo.png)

[![Crystal CI](https://github.com/azutoolkit/joobq/actions/workflows/crystal.yml/badge.svg)](https://github.com/azutoolkit/joobq/actions/workflows/crystal.yml)

JoobQ is a fast, efficient, and reliable asynchronous job queue scheduler library. Jobs are submitted to a job queue, where they reside until they are scheduled to run in a compute environment.

## Table of Contents

- [JoobQ](#joobq)
  - [Table of Contents](#table-of-contents)
  - [Getting Started](#getting-started)
    - [Prerequisites](#prerequisites)
    - [Setting Up](#setting-up)
  - [Features](#features)
  - [Installation](#installation)
  - [Usage](#usage)
    - [Environment Variables](#environment-variables)
    - [Defining Queues](#defining-queues)
  - [Configuration](#configuration)
  - [JoobQ Rest API](#joobq-rest-api)
    - [HTTP Serer](#http-serer)
    - [Rest API](#rest-api)
    - [GET /joobq/jobs/registry](#get-joobqjobsregistry)
    - [POST /joobq/jobs](#post-joobqjobs)
    - [GET /joob/metrics](#get-joobmetrics)
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

## Features

- Priority queues based on the number of workers
- Reliable queue
- Error handling
- Retry jobs with automatic delays
- Cron-like periodic jobs
- Delayed jobs
- Stop execution of workers
- Job expiration
- Throttle (Rate limit)
- Rest API
- Throttle (Rate limit)
- Graceful Termination

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

### Defining Queues

Queues are of type Hash(String, Queue(T)) where the name of the key matches the name of the Queue.

**Example:**

```crystal
JoobQ.configure do
  queue name: "single", workers: 10, job: Job1, throttle_limit: nil
  queue "example", 10, ExampleJob | FailJob
  # Scheduling Recurring Jobs
  scheduler do
    cron("*/1 * * * *") { # Do Something }
    cron("*/5 20-23 * * *") { # Do Something }
    every 1.hour, ExampleJob, x: 1
  end
end
```

**Jobs:**

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

**Executing Job**

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

**Running JoobQ:**

Starts JoobQ server and listens for jobs

```crystal
JoobQ.forge
```

Output

```console
~/Workspaces/joobq · (master±)
⟩ ./joobq
2024-11-16T11:32:19.020231Z   INFO - JoobQ starting...
2024-11-16T11:32:19.020242Z   INFO - JoobQ starting queue:test queue...
2024-11-16T11:32:24.123613Z   INFO - JoobQ initialized and waiting for Jobs...
Listening on http://0.0.0.0:8080
```

## Configuration

JoobQ can be configured using the JoobQ.configure method. Here is an example configuration:

```crystal
JoobQ.configure do
  queue "default", 10, EmailJob
  scheduler do
    cron("*/1 * * * *") { # Do Something }
    every 1.hour, EmailJob, email_address: "john.doe@example.com"
  end
end
```

## JoobQ Rest API

### HTTP Serer

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

{
  "queue": "default",
  "job": "EmailJob",
  "email_address": "john.doe@example.com"
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

This endmpoint returns metrics about the queue

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
