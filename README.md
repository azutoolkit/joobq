# JoobQ

JoobQ is a fast, efficient asynchronous reliable job queue scheduler library processing. Jobs are submitted
to a job queue, where they reside until they are able to be scheduled to run in a
compute environment.

**Features:**

* [x] Priority queues based on number of workers
* [x] Reliable queue
* [x] Error Handling
* [x] Retry Jobs with automatic Delays
* [x] Cron Like Periodic Jobs
* [x] Delayed Jobs
* [/] Stop execution of workers
* [] Expiring Jobs: Jobs to expire after certain time
* [] Rest API: Rest api to schedule jobs
* [] Approve Queue?: Jobs have to manually approved to execute
* [] Job Locking / Disable Concurrent Execution (1 Job Per Instance)
* [] Throttle (Rate limit)
* [] CLI to manage queues and monitor server

## Installation

```yaml
dependencies:
    joobq:
        github: eliasjpr/joobq
```

Then run:

``` bash
shards install
```

## Configuration Options

```crystal
module JoobQ
  # Each worker job capacity
  workers_capacity = 1
  
  # Define Queues
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
  @queue = "default"    # Name of the queue to be processed by
  @retries : Int32 = 0  # Number Of Retries for this job

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

## How To Integrate

TODO: Define how JoobQ can be used outside of Crystal another language

## Contributing

1. Fork it (<https://github.com/your-github-user/joobq/fork>)
2. Create your feature branch ( `git checkout -b my-new-feature` )
3. Commit your changes ( `git commit -am 'Add some feature'` )
4. Push to the branch ( `git push origin my-new-feature` )
5. Create a new Pull Request

## Contributors

* [Elias J. Perez](https://github.com/your-github-user) - creator and maintainer
