require "../../src/joobq"

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
