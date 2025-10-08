
# Define job classes for testing BEFORE loading configuration
class Job1
  include JoobQ::Job

  def initialize
    @queue = "single"
  end

  def perform
    # Simple test job
  end
end

class ExampleJob
  include JoobQ::Job

  getter x : Int32

  def initialize(@x : Int32 = 0)
    @queue = "example"
  end

  def perform
    @x += 1
  end
end

class FailJob
  include JoobQ::Job

  def initialize
    @queue = "failed"
  end

  def perform
    raise "This job always fails"
  end
end
class TestJob
  include JoobQ::Job

  getter x
  @queue = "example"

  def initialize(@x : Int32 = 0)
  end

  def perform
    @x += 1
  end
end
# Test jobs for retry refactor tests
struct RetryTestJob
  include JoobQ::Job

  property x : Int32

  def initialize(@x : Int32)
    @queue = "example"
    @retries = 3
    @max_retries = 3
  end

  def perform
    @x + 1
  end
end

struct FailingRetryJob
  include JoobQ::Job

  property fail_count : Int32

  def initialize(@fail_count : Int32 = 0)
    @queue = "example"
    @retries = 3
    @max_retries = 3
  end

  def perform
    raise "Intentional failure"
  end
end

struct NoRetryFailJob
  include JoobQ::Job

  def initialize
    @queue = "example"
    @retries = 0
    @max_retries = 0
  end

  def perform
    raise "Immediate failure"
  end
end
# Define test job classes
class ErrorMonitorTestJob
  include JoobQ::Job

  getter x : Int32
  @queue = "example"
  @retries = 3

  def initialize(@x : Int32)
  end

  def perform
    @x + 1
  end
end

# Test job classes for queue factory specs
class FactoryTestJob
  include JoobQ::Job

  property data : String

  def initialize(@data : String = "test")
  end

  def perform
    # Test job - does nothing
  end
end

class AnotherFactoryTestJob
  include JoobQ::Job

  property value : Int32

  def initialize(@value : Int32 = 42)
  end

  def perform
    # Test job - does nothing
  end
end

class ThrottledFactoryTestJob
  include JoobQ::Job

  property name : String

  def initialize(@name : String = "throttled")
  end

  def perform
    # Test job - does nothing
  end
end

