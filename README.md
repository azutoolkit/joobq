# JoobQ

![Crystal CI](https://github.com/eliasjpr/joobq/workflows/Crystal%20CI/badge.svg?branch=master)

JoobQ is a fast, efficient asynchronous reliable job queue scheduler library
processing. Jobs are submitted to a job queue, where they reside until they are
able to be scheduled to run in a compute environment.

#### Features:

- [x] Priority queues based on number of workers
- [x] Reliable queue
- [x] Error Handling
- [x] Retry Jobs with automatic Delays
- [x] Cron Like Periodic Jobs
- [x] Delayed Jobs
- [x] Stop execution of workers
- [x] Jobs expiration

## Help Wanted

- \[ ] CLI to manage queues and monitor server
- \[ ] Rest API: Rest api to schedule jobs
- \[ ] Throttle (Rate limit)
- \[ ] Approve Queue?: Jobs have to manually approved to execute

## Installation

```yaml
dependencies:
  joobq:
    github: azutoolkit/joobq
```

Then run:

```bash
shards install
```

## Requirements

This project uses REDIS with the TimeSeries module loaded. The Redis TimeSeries
is used to monitor stats of job execution the module is free for use and easy to
configure. Follow the guidelines at [redistimeseries.io](https://oss.redislabs.com/redistimeseries/)

## Usage

```crystal
require "joobq"
```

### Environment variables

```shell
REDIS_HOST=localhost
REDIS_PORT=6379
REDIS_POOL_SIZE=50
REDIS_TIMEOUT=0.2
```

## Defining Queues

Defining Queues: Queues are of type `Hash(String, Queue(T))` where the name of
the key matches the name of the Queue.

### Properties

- **Name:** `queue:email`
- **Number Workers:** 10
- **Job Class:** TestJob - a class or union of classes

### Example

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

## Jobs

To define Jobs, must include the JoobQ::Job module, and must implement perform method

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

### Executing Job

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

## Running JoobQ

Starts JoobQ server and listens for jobs

```crystal
JoobQ.forge
```

## Statistics

JoobQ includes a Statistics class that allow you get stats about queue performance.

### Available stats

```text
total enqueued jobs
total, percent completed jobs
total, percent retry jobs
total, percent dead jobs
total busy jobs
total delayed jobs
```

## Contributing

1. Fork it (<https://github.com/eliasjpr/joobq/fork>)
2. Create your feature branch ( `git checkout -b my-new-feature` )
3. Commit your changes ( `git commit -am 'Add some feature'` )
4. Push to the branch ( `git push origin my-new-feature` )
5. Create a new Pull Request

## Contributors

- [Elias J. Perez](https://github.com/eliasjpr) - creator and maintainer
