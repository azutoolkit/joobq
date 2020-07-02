require "../src/joobq"
require "benchmark"

struct TestJob
  include JoobQ::Job

  property x : Int32
  @retries = 3
  @queue = "queue:test"

  def initialize(@x : Int32)
  end

  def perform
    x + 1
  end
end

struct FailJob
  include JoobQ::Job
  @queue = "queue:fail"
  @retries = 3

  def initialize
  end

  def perform
    raise "Bad"
  end
end

JoobQ.reset

module JoobQ
  QUEUES = {
    "queue:test" => JoobQ::Queue(TestJob).new("queue:test", 80),
    "queue:fail" => JoobQ::Queue(FailJob).new("queue:fail", 20),
  }
end

JoobQ.run

sleep
