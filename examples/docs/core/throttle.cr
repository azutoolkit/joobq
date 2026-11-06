require "joobq"

STARTED = Time.instant

struct SendSmsJob
  include JoobQ::Job

  @queue = "sms"
  @@sent = Atomic(Int32).new(0)
  getter message_id : Int32

  def initialize(@message_id : Int32)
  end

  def self.sent
    @@sent.get
  end

  def perform
    puts "SMS #{message_id} at #{(Time.instant - STARTED).total_seconds.round(1)}s"
    @@sent.add(1)
  end
end

JoobQ.configure do |config|
  config.rest_api_enabled = false
  # At most 2 per second in this process: one job every 500 ms, whatever the worker count.
  queue "sms", 4, SendSmsJob, {limit: 2, period: 1.second}
end

5.times { |id| SendSmsJob.enqueue(message_id: id + 1) }
spawn { JoobQ.forge(trap_signals: false) }
until SendSmsJob.sent == 5
  sleep 50.milliseconds
end
JoobQ.shutdown(5.seconds)
puts "throttled: 5 jobs"
