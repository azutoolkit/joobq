# Live-process probe for scripts/redis_outage_smoke.py, never the shared test Redis. It runs PROBE_JOBS jobs that take
# PROBE_JOB_SECONDS each (so Redis is away as they end), writes `done-<number>` into PROBE_DIR when one finishes, and
# exits 0 once every number is done, 1 after PROBE_LIMIT seconds. It is never restarted: what runs the lost jobs
# again is the process re-driving its retained copies.
require "../../src/joobq"

class OutageProbeJob
  include JoobQ::Job
  property number : Int32

  def initialize(@number)
    @queue = "outage_probe"
  end

  def perform
    File.write(File.join(ENV["PROBE_DIR"], "started-#{number}-#{Random::Secure.hex(3)}"), "")
    sleep ENV["PROBE_JOB_SECONDS"].to_f.seconds
    File.write(File.join(ENV["PROBE_DIR"], "done-#{number}"), "")
  end
end

jobs = ENV["PROBE_JOBS"].to_i # the queue below has 12 workers: PROBE_JOBS must be 12
JoobQ.set_config(JoobQ::Configure.new)
JoobQ.config.timeout = 10.minutes
JoobQ.configure do
  queue "outage_probe", 12, OutageProbeJob
end
jobs.times { |i| JoobQ.add(OutageProbeJob.new(i)) }
JoobQ.config.queues.each_value(&.start)

# Finished means: every job ran to its end AND Redis holds nothing for the queue (no waiting job, no processing copy).
# A copy whose outcome was not stored stays in the processing list for good unless the process re-drives it.
store = JoobQ.store.as(JoobQ::RedisStore)
drained = -> do
  store.queue_size("outage_probe") == 0 && store.processing_queue_size("outage_probe") == 0
  rescue
    false # Redis is away
end
done = -> { Dir.glob(File.join(ENV["PROBE_DIR"], "done-*")).size }

deadline = Time.instant + ENV["PROBE_LIMIT"].to_f.seconds
until done.call >= jobs && drained.call
  if Time.instant > deadline
    STDERR.puts "FAIL: #{done.call}/#{jobs} jobs done, queue drained: #{drained.call}"
    exit 1
  end
  sleep 100.milliseconds
end
puts "PASS: #{jobs}/#{jobs} jobs done and settled without a process restart"
exit 0
