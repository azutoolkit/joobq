# JoobQ

![Crystal CI](https://github.com/eliasjpr/joobq/workflows/Crystal%20CI/badge.svg?branch=master) [![Codacy Badge](https://app.codacy.com/project/badge/Grade/757ebd7d1db942da8eb9f8392415b1a6)](https://www.codacy.com/manual/eliasjpr/joobq?utm_source=github.com&utm_medium=referral&utm_content=eliasjpr/joobq&utm_campaign=Badge_Grade)

JoobQ is a fast, efficient asynchronous reliable job queue scheduler library processing. Jobs are submitted
to a job queue, where they reside until they are able to be scheduled to run in a
compute environment.

**Features:**

-   [x] Priority queues based on number of workers
-   [x] Reliable queue
-   [x] Error Handling
-   [x] Retry Jobs with automatic Delays
-   [x] Cron Like Periodic Jobs
-   [x] Delayed Jobs
-   [x] Stop execution of workers
-   [x] Expiring Jobs: Jobs to expire after certain time
-   \[] Rest API: Rest api to schedule jobs
-   \[] Approve Queue?: Jobs have to manually approved to execute
-   \[] Job Locking / Disable Concurrent Execution (1 Job Per Instance)
-   \[] Throttle (Rate limit)
-   \[] CLI to manage queues and monitor server

## Installation

```yaml
dependencies:
  joobq:
    github: eliasjpr/joobq
```

Then run:

```bash
shards install
```

## Requirements

This project uses REDIS with the Time Series as the database for the Jobs.

## Redis Time Series Configuration

Use DUPLICATE POLICY first to ignore duplicate entries

```bash
redis-server --loadmodule ./redistimeseries.so DUPLICATE_POLICY FIRST
```
## Configuration Options

```crystal
require "joobq"
```

**Environment variables**

```crystal
REDIS_HOST=localhost
REDIS_PORT=6379
REDIS_POOL_SIZE=50
REDIS_TIMEOUT=0.2
```

**In App Configuration**

```crystal
module JoobQ
  # Define Queues
  # Queue Name = `queue:email`
  # Queue No. Workers = 10
  QUEUES = { "queue:email" => Queue(EmailJob).new("queue:email", 10)}

  # Define recurring jobs
  scheduler.define do
    at("5 4 * * *") { Somejob.perform }
  end
end
```

## Job Definition

```crystal
struct EmailJob
  include JoobQ::Job
  @queue   = "default"    # Name of the queue to be processed by
  @retries = 0  # Number Of Retries for this job
  @expires = 1.days.total_seconds.to_i
  
  # Define initializers as normal with or without named tuple arguments
  def initialize(email_address : String)
  end

  def perform
    # Logic to handle job execution
  end
end

# Perform Job
EmailJob.perform(email_address: "john.doe@example.com")
EmailJob.perform(within: 1.hour, email_address: "john.doe@example.com")
```

Start JoobQ server to start forging jobs

```crystal
JoobQ.forge
```

## Statistics

JoobQ includes a Statistics class that allow you get stats about queue performance. 

**Available stats**

```
total enqueued jobs
total, percent completed jobs
total, percent retry jobs
total, percent dead jobs
total busy jobs
total delayed jobs
```
## How To Integrate

TODO: Define how JoobQ can be used outside of Crystal another language

## Contributing

1.  Fork it (<https://github.com/eliasjpr/joobq/fork>)
2.  Create your feature branch ( `git checkout -b my-new-feature` )
3.  Commit your changes ( `git commit -am 'Add some feature'` )
4.  Push to the branch ( `git push origin my-new-feature` )
5.  Create a new Pull Request

## Contributors

-   [Elias J. Perez](https://github.com/eliasjpr) - creator and maintainer
