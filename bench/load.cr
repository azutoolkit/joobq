require "../src/joobq"

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


1000000.times do |i|
  TestJob.perform(x: i)
  FailJob.perform
end
