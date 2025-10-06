require "spec"
require "../src/joobq"
require "./jobs_spec"

# Define job classes for testing
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

JoobQ.configure do
  queue "single", 10, Job1
  queue "example", 10, ExampleJob
  queue "failed", 10, FailJob

  scheduler do
    cron(pattern: "*/30 * * * *") { puts "Every 30 seconds #{Time.local}" }
    cron(pattern: "*/5 20-23 * * *") { }
    every(1.minute, ExampleJob, x: 1)
  end
end
