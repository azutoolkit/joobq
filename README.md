# JoobQ

<img src="./joobq-logo.png" alt="JoobQ Logo">

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
  - [API Documentation](#api-documentation)
    - [GET /jobs/registry](#get-jobsregistry)
    - [POST /enqueue](#post-enqueue)
  - [Contributing](#contributing)
  - [Testing](#testing)
  - [Deployment](#deployment)
  - [Roadmap](#roadmap)
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

**Example**

```crystal
JoobQ.configure do
  queue "single", 10, Job1
  queue "example", 10, ExampleJob | FailJob
  # Scheduling Recurring Jobs
  scheduler do
    cron("*/1 * * * *") { # Do Something }
    cron("*/5 20-23 * * *") { # Do Something }
    every 1.hour, ExampleJob, x: 1
  end
end
```

**Jobs**

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
# Perform Immediately
EmailJob.new(email_address: "john.doe@example.com").perform

# Async - Adds to Queue
EmailJob.perform(email_address: "john.doe@example.com")

# Delayed
EmailJob.delay(for: 1.hour, email_address: "john.doe@example.com")

# Recurring at given interval
EmailJob.schedule(every: 1.second, email_address: "john.doe@example.com")
```

**Running JoobQ**

Starts JoobQ server and listens for jobs

```crystal
JoobQ.forge
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

## API Documentation

JoobQ provides a REST API to interact with the job queue. Below are the available endpoints:

### GET /jobs/registry

This endpoint returns all available registered jobs and their JSON schemas that can be enqueued via the REST API.

**Request:**

```httpie
GET /jobs/registry HTTP/1.1
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

### POST /enqueue

This endpoint allows users to enqueue jobs.

**Request:**

```httpie
POST /enqueue HTTP/1.1
Host: localhost:8080
Content-Type: application/json

{
  "queue": "default",
  "job": "EmailJob",
  "args": {
    "email_address": "john.doe@example.com"
  }
}
```

**Response**

```json
{
  "status": "Job enqueued",
  "queue": "default",
  "job": "EmailJob"
}
```

## Contributing

1. Fork it (https://github.com/azutoolkit/joobq/fork)
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

To deploy JoobQ, ensure that you have a running Redis instance with the TimeSeries module. You can use the provided docker-compose.yml to set up Redis.

```bash
docker-compose up -d
```

## Roadmap

- [ ] CLI to manage queues and monitor server
- [ ] Extend the REST API for more functionality
- [ ] Approve Queue: Jobs have to be manually approved to execute
      License
      The MIT License (MIT). Please see License File for more information.

## Acknowledgments

Elias J. Perez - creator and maintainer
Crystal Language
Redis
