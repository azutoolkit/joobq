require "joobq"

STARTED = Time.instant

struct SyncCrmContactJob
  include JoobQ::Job

  @queue = "crm"
  getter contact_id : Int64

  def initialize(@contact_id : Int64)
  end

  def perform
    puts "Attempt #{max_retries - retries + 1} at #{(Time.instant - STARTED).total_seconds.round(1)}s"
    raise "CRM answered 503"
  end
end

struct ChargeCardJob
  include JoobQ::Job

  @queue = "payments"

  class Declined < JoobQ::NonRetryableError
  end

  def initialize
  end

  def perform
    puts "ChargeCardJob ran once"
    raise Declined.new("card declined")
  end
end

JoobQ.configure do |config|
  config.rest_api_enabled = false
  queue "crm", 1, SyncCrmContactJob
  queue "payments", 1, ChargeCardJob
end

dlq = JoobQ::DeadLetterQueue.new
spawn { JoobQ.forge(trap_signals: false) }
SyncCrmContactJob.enqueue(contact_id: 7_i64)
ChargeCardJob.enqueue
until dlq.count("crm") + dlq.count("payments") == 2
  sleep 100.milliseconds
end
JoobQ.shutdown(5.seconds)
(dlq.page(queue: "crm") + dlq.page(queue: "payments")).each { |entry| puts "Dead letter (#{entry.queue}): #{entry.error}" }
