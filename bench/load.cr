require "../src/joobq"

JoobQ.configure do |_|
  queue "queue:test", 80, TestJob
  queue "queue:fail", 20, FailJob
end

struct TestJob
  include JoobQ::Job

  property x : Int32
  @retries = 2
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

1_000.times do |i|
  TestJob.perform(x: i)
  # FailJob.perform
end

puts "Enqueued 1,000,000 jobs"
