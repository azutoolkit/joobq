require "joobq"

struct SendDigestJob
  include JoobQ::Job

  @queue = "digests"
  @@sent = Atomic(Int32).new(0)
  getter list : String

  def initialize(@list : String)
  end

  def self.sent
    @@sent.get
  end

  def perform
    @@sent.add(1)
    puts "Sent the #{list} digest"
  end
end

JoobQ.configure do |config|
  config.rest_api_enabled = false
  queue "digests", 1, SendDigestJob

  # Six fields: the first is seconds. The block only enqueues, so the job keeps its retries.
  scheduler(Time::Location.load("UTC")) do
    cron("*/2 * * * * *") { SendDigestJob.enqueue(list: "weekly") }
  end
end

spawn { JoobQ.forge(trap_signals: false) }
until SendDigestJob.sent == 2
  sleep 100.milliseconds
end
JoobQ.shutdown(5.seconds)
puts "cron enqueued 2 digests"
