require "../src/joobq"
JoobQ.configure do |_|
  queue "queue:test", 30, TestJob
  queue "queue:fail", 20, FailJob
end

struct TestJob
  include JoobQ::Job

  property x : Int32
  @retries = 3
  @queue = "queue:test"

  def initialize(@x : Int32)
  end

  def perform
    random = Random.rand(100)

    if random > 98
      raise "Bad"
    end

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

JoobQ.forge
sleep
