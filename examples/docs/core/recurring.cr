require "joobq"

struct PurgeExpiredSessionsJob
  include JoobQ::Job

  @queue = "maintenance"
  @@runs = Atomic(Int32).new(0)

  def initialize
  end

  def self.runs
    @@runs.get
  end

  def perform
    @@runs.add(1)
    raise "session store unavailable"
  end
end

JoobQ.configure do |config|
  config.rest_api_enabled = false
  queue "maintenance", 1, PurgeExpiredSessionsJob
end

# `schedule(every:)` calls perform in this process: no queue, no retry, no dead letter.
PurgeExpiredSessionsJob.schedule(every: 500.milliseconds)
sleep 1200.milliseconds
JoobQ.shutdown(5.seconds)
puts "perform calls: #{PurgeExpiredSessionsJob.runs}"
puts "queued: #{JoobQ.store.queue_size("maintenance")}, dead letters: #{JoobQ::DeadLetterQueue.new.count("maintenance")}"
