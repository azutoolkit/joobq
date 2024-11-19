require "../../src/joobq"

struct TestJob
  include JoobQ::Job

  property x : Int32
  @retries = 2
  @queue = "queue:test"

  def initialize(@x : Int32)
  end

  def perform
    random = Random.rand(100)

    if random > 99
      raise "Bad"
    end

    x + 1
  end
end
