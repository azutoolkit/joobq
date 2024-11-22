require "../../src/joobq"

struct ExpireJob
  include JoobQ::Job
  @queue = "queue:expire"
  @retries = 2
  @expires = 5.seconds.from_now.to_unix_ms

  def initialize
  end

  def perform
  end
end
