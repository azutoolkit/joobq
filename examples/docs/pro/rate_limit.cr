require "joobq_pro"

STARTED = Time.instant

struct CallPartnerApiJob
  include JoobQ::Job
  include JoobQPro::RateLimited

  @queue = "partner-api"
  @@calls = Atomic(Int32).new(0)
  rate_limit count: 2, period: 1.second
  getter request_id : Int32

  def initialize(@request_id : Int32)
  end

  def self.calls
    @@calls.get
  end

  def perform
    puts "Request #{request_id} at #{(Time.instant - STARTED).total_seconds.round(1)}s"
    @@calls.add(1)
  end
end

JoobQ.configure do |config|
  config.rest_api_enabled = false
  # Not installed by default: add it yourself, before the retry middleware.
  config.middlewares.unshift(JoobQPro::RateLimitMiddleware.new)
  queue "partner-api", 4, CallPartnerApiJob
end

6.times { |id| CallPartnerApiJob.enqueue(request_id: id + 1) }
spawn { JoobQ.forge(trap_signals: false) }
until CallPartnerApiJob.calls == 6
  sleep 50.milliseconds
end
JoobQ.shutdown(5.seconds)
puts "PASS 6 requests, at most 2 per second"
