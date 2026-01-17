# JoobQ Job Creation Patterns

## Basic Job Structure

```crystal
class MyJob
  include JoobQ::Job

  # Configure queue assignment
  @queue = "default"

  # Configure retry behavior
  @retries = 3
  @max_retries = 3

  # Job arguments (must be JSON serializable primitives)
  getter user_id : Int32
  getter action : String

  def initialize(@user_id : Int32, @action : String = "process")
  end

  def perform
    # Job logic here
    # Access job properties: jid, queue, status, retries
  end
end
```

## Job Registration

After defining a job, register it for YAML-based queue creation:

```crystal
JoobQ::QueueFactory.register_job_type(MyJob)
```

## Enqueuing Jobs

```crystal
# Immediate enqueue
MyJob.enqueue(user_id: 123, action: "send_email")

# Batch enqueue (up to 1000 jobs)
jobs = (1..100).map { |i| MyJob.new(user_id: i) }
MyJob.batch_enqueue(jobs)

# Delayed execution
MyJob.delay(for: 5.minutes, user_id: 123)
MyJob.enqueue_at(10.minutes, user_id: 123)

# Recurring schedule
MyJob.schedule(every: 1.hour, user_id: 123)
```

## Job Status Methods

```crystal
# Check status
job.enqueued?    # Check if enqueued
job.running?     # Check if running
job.completed?   # Check if completed
job.retrying?    # Check if retrying
job.dead?        # Check if in dead letter
job.expired?     # Check if expired

# Set status
job.running!     # Set to running
job.completed!   # Set to completed
job.dead!        # Set to dead
```

## Job Properties

| Property | Type | Description |
|----------|------|-------------|
| `jid` | UUID | Unique job identifier |
| `queue` | String | Queue name |
| `status` | Status | Current job status |
| `retries` | Int32 | Remaining retry count |
| `max_retries` | Int32 | Maximum retries allowed |
| `expires` | Time | Job expiration time |
| `error` | NamedTuple? | Error information if failed |

## Best Practices

1. **Idempotency**: Jobs must be safe to retry - same input should produce same result
2. **Simple Arguments**: Use JSON primitives (Int32, String, Bool, Float64)
3. **Limited Arguments**: Keep to 3-5 parameters maximum
4. **Error Context**: Let middleware handle errors, don't swallow exceptions
5. **No Side Effects in Initialize**: Only perform work in `perform` method
6. **Short Jobs**: Keep jobs under 30 seconds; split long tasks into multiple jobs

## Example Jobs

### Email Job

```crystal
class SendEmailJob
  include JoobQ::Job

  @queue = "emails"
  @retries = 3

  getter to : String
  getter subject : String
  getter body : String

  def initialize(@to : String, @subject : String, @body : String)
  end

  def perform
    EmailService.send(to: @to, subject: @subject, body: @body)
  end
end
```

### Data Processing Job

```crystal
class ProcessDataJob
  include JoobQ::Job

  @queue = "processing"
  @retries = 5

  getter record_id : Int64
  getter operation : String

  def initialize(@record_id : Int64, @operation : String = "transform")
  end

  def perform
    record = Database.find(@record_id)
    case @operation
    when "transform"
      record.transform!
    when "validate"
      record.validate!
    end
  end
end
```
