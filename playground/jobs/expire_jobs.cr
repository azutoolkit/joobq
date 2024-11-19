require "../../src/joobq"

struct ExpireJob
  include JoobQ::Job
  @queue = "queue:expire"
  @retries = 2

  def initialize
  end

  def perform
  end
end
