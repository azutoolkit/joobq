---
description: Create a new JoobQ job class with proper structure and registration
---

# Create Job

Create a new job class for JoobQ.

## Information Needed

1. **Job name** (e.g., `SendEmailJob`, `ProcessImageJob`)
2. **Queue name** (e.g., `emails`, `images`, `default`)
3. **Arguments** (e.g., `user_id: Int32`, `email: String`)
4. **Retry count** (default: 3)

## Template

```crystal
class {JobName}
  include JoobQ::Job

  @queue = "{queue_name}"
  @retries = {retry_count}
  @max_retries = {retry_count}

  getter {arg1} : {Type1}
  getter {arg2} : {Type2}

  def initialize(@{arg1} : {Type1}, @{arg2} : {Type2} = default_value)
  end

  def perform
    # TODO: Implement job logic
    # Available: jid, queue, status, retries, expires
  end
end
```

## After Creation

1. Register the job in `spec/spec_helper.cr`:
   ```crystal
   JoobQ::QueueFactory.register_job_type({JobName})
   ```

2. Add queue configuration in `config/joobq.*.yml` or programmatically:
   ```crystal
   queue "{queue_name}", 10, {JobName}
   ```

3. Create spec file at `spec/{job_name_snake}_spec.cr`

## File Location

Jobs should be placed in `src/jobs/` or the appropriate domain folder.

## Usage Examples

```crystal
# Immediate execution
{JobName}.enqueue(arg1: value1, arg2: value2)

# Delayed execution
{JobName}.delay(for: 5.minutes, arg1: value1)

# Batch enqueue
jobs = items.map { |item| {JobName}.new(arg1: item) }
{JobName}.batch_enqueue(jobs)
```
