# Worker process for scripts/crash_recovery_smoke.py, never the shared test Redis. It serves a Core queue of PROBE_JOBS
# workers with the owner TTL PROBE_TTL_MS and the reaper interval PROBE_INTERVAL_MS. Each run of a job writes
# `attempt-<number>-<pid>` into PROBE_DIR when it starts and `done-<number>-<pid>` after PROBE_JOB_SECONDS. With
# PROBE_SEED=1 it first enqueues the jobs. It exits 0 once every job number is done and Redis holds nothing for the
# queue (no waiting job, no processing copy), 1 after PROBE_LIMIT seconds.
require "../../src/joobq"

class CrashProbeJob
  include JoobQ::Job
  property number : Int32

  def initialize(@number)
    @queue = "crash_probe"
  end

  def perform
    File.write(File.join(ENV["PROBE_DIR"], "attempt-#{number}-#{Process.pid}"), "")
    sleep ENV["PROBE_JOB_SECONDS"].to_f.seconds
    File.write(File.join(ENV["PROBE_DIR"], "done-#{number}-#{Process.pid}"), "")
  end
end

jobs = ENV["PROBE_JOBS"].to_i # the queue below has 12 workers: PROBE_JOBS must be 12
JoobQ.set_config(JoobQ::Configure.new)
config = JoobQ.config
config.owner_ttl = ENV["PROBE_TTL_MS"].to_i.milliseconds
config.reaper_interval = ENV["PROBE_INTERVAL_MS"].to_i.milliseconds
config.validate_recovery_timing
JoobQ.configure do
  queue "crash_probe", 12, CrashProbeJob
end
jobs.times { |i| JoobQ.add(CrashProbeJob.new(i)) } if ENV["PROBE_SEED"]? == "1"
config.expired_job_reaper.start
config.queues.each_value(&.start)

store = JoobQ.store.as(JoobQ::RedisStore)
drained = -> do
  store.queue_size("crash_probe") == 0 && store.processing_queue_size("crash_probe") == 0
  rescue
    false
end
done = -> { Dir.glob(File.join(ENV["PROBE_DIR"], "done-*")).map { |path| File.basename(path).split('-')[1] }.uniq.size }

deadline = Time.instant + ENV["PROBE_LIMIT"].to_f.seconds
until done.call >= jobs && drained.call
  if Time.instant > deadline
    STDERR.puts "FAIL: #{done.call}/#{jobs} jobs done, queue drained: #{drained.call}"
    exit 1
  end
  sleep 100.milliseconds
end
puts "PASS: #{jobs}/#{jobs} jobs done and settled"
exit 0
