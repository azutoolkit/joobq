---
description: Create a new spec test file for JoobQ
---

# Create Test File

Generate a new spec file.

## Information Needed

1. **Component to test** (job, queue, middleware, etc.)
2. **Class/module name**
3. **Key behaviors to test**

## Template

```crystal
require "./spec_helper"

module JoobQ
  describe {ClassName} do
    before_each do
      JoobQ.reset
    end

    describe "#{method_name}" do
      it "does expected behavior" do
        # Arrange
        {setup_code}

        # Act
        {action_code}

        # Assert
        {result}.should eq({expected})
      end

      it "handles error case" do
        expect_raises({ExceptionClass}) do
          {error_triggering_code}
        end
      end
    end
  end
end
```

## File Location

Place in `spec/{component_name}_spec.cr`

## Common Patterns

```crystal
# Test job enqueue
ExampleJob.enqueue(x: 1)
JoobQ.store.queue_size("example").should eq(1)

# Test queue processing
queue.start
sleep 0.5.seconds
queue.size.should eq(0)
queue.stop!

# Test Redis interactions
store = JoobQ.store.as(RedisStore)
store.redis.llen("queue_name").should eq(expected)

# Test middleware
next_middleware = -> { }
middleware.call(job, queue, "worker-1", next_middleware)
```

## Test Job Helpers

From `spec/helpers/all_test_jobs.cr`:
- `Job1` - Simple job
- `ExampleJob` - Job with x argument
- `FailJob` - Always raises
- `RetryTestJob` - Has retry config
- `NoRetryFailJob` - Fails with no retries
