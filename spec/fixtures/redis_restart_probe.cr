# Storage durability probe for scripts/redis_restart_smoke.py, never the shared test Redis.
require "../../src/joobq"

class RestartProbeJob
  include JoobQ::Job
  property number : Int32

  def initialize(@number)
    @queue = "restart_probe"
  end

  def perform
  end
end

store = JoobQ::RedisStore.new
case ARGV.first?
when "seed"
  jobs = Array(JoobQ::Job).new(1000) { |i| RestartProbeJob.new(i).as(JoobQ::Job) }
  store.enqueue_batch(jobs)
  claimed = store.dequeue_batch("restart_probe", RestartProbeJob, 10)
  raise "claim count mismatch" unless claimed.size == 10
when "verify"
  ready = store.redis.lrange("restart_probe", 0, -1)
  processing = store.redis.lrange("joobq:processing:restart_probe", 0, -1)
  raise "lost ready jobs" unless ready.size == 990
  raise "lost claimed jobs" unless processing.size == 10
  numbers = (ready + processing).map { |raw| RestartProbeJob.from_json(raw.as(String)).number }.sort
  raise "missing or duplicate payloads" unless numbers == (0...1000).to_a
  puts "PASS: 990 queued + 10 claimed payloads survived Redis SIGKILL/AOF restart"
else
  raise "expected seed or verify"
end
