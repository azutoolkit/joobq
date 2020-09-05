require "spec"
require "../src/joobq"

struct FailJob
  include JoobQ::Job

  @queue = "example"
  @retries = 0

  def initialize
  end

  def perform
    raise "Bad"
  end
end

struct ExampleJob
  include JoobQ::Job

  property x : Int32
  @retries = 3

  def initialize(@x : Int32)
    @queue = "example"
  end

  def perform
    x + 1
  end
end

struct Job1
  include JoobQ::Job
  @retries = 0
  @queue = "single"

  def initialize
  end

  def perform
  end
end

module JoobQ
  QUEUES = {
    "single"       => Queue(Job1).new("single", 10),
    "example"      => Queue(ExampleJob | FailJob).new("example", 1),
  }
end
