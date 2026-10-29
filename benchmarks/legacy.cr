require "../src/joobq"

# Exercises Queue/Worker/Scheduler, not Delivery. Run only through the owned
# integration harness. Keep logging/middleware settings identical across builds.
class LegacyAllocationJob
  include JoobQ::Job
  getter index : Int32
  getter payload : String

  def initialize(@index, @payload, @queue)
    @expires = 1.hour.from_now.to_unix_ms
  end

  def perform
  end
end

{% unless flag?(:preview_mt) && !flag?(:execution_context) %}
  Fiber::ExecutionContext.default.resize(ENV.fetch("CRYSTAL_WORKERS", "4").to_i)
{% end %}
Log.setup(:warn)
count = ENV.fetch("BENCH_JOBS", "10000").to_i
mode = ENV.fetch("BENCH_MODE", "worker")
raise "invalid benchmark mode" unless {"queue", "worker", "scheduler"}.includes?(mode)
raise "BENCH_JOBS must be 1..100000" unless 1 <= count <= 100000
store = JoobQ::RedisStore.new(url: ENV.fetch("JOOBQ_SPEC_TLS_REDIS_URL"),
  ca_file: ENV.fetch("JOOBQ_SPEC_TLS_CA_FILE"), pool_size: 24)
JoobQ.config.store = store
JoobQ.config.worker_batch_size = 128
JoobQ.config.pipeline_batch_size = 100
queue_name = "legacy-bench-#{UUID.random}"
seen = Array.new(count, false)
completed = 0
lock = Sync::Mutex.new
queue = JoobQ::Queue(LegacyAllocationJob).new(queue_name, 4, store: store, handler: ->(job : LegacyAllocationJob) {
  lock.synchronize do
    raise "duplicate/out-of-range execution" unless 0 <= job.index < count && !seen[job.index]
    seen[job.index] = true
    completed += 1
  end
  nil
})
payload = "x" * 1024
raws = Array.new(count) do |i|
  job = LegacyAllocationJob.new(i, payload, queue_name)
  job.scheduled! if mode == "scheduler"
  job.to_json
end
workers = [] of JoobQ::Worker(LegacyAllocationJob)
scheduler = JoobQ::Scheduler.new(store: store)
if mode == "worker"
  raws.each_slice(100) { |batch| queue.add_batch_strings(batch) }
elsif mode == "scheduler"
  raws.each_slice(100) do |batch|
    store.redis.pipelined { |pipe| batch.each { |raw| pipe.zadd(JoobQ::RedisStore::DELAYED_SET, 0, raw) } }
  end
end
before = GC.stats.total_bytes
started = Time.instant
case mode
when "queue"
  raws.each_slice(100) { |batch| queue.add_batch_strings(batch) }
when "scheduler"
  while store.redis.zcard(JoobQ::RedisStore::DELAYED_SET) > 0
    scheduler.enqueue_due_jobs
    raise "scheduler timeout" if Time.instant - started > 120.seconds
  end
when "worker"
  workers = Array.new(4) { |i| JoobQ::Worker(LegacyAllocationJob).new(i, Channel(Nil).new(1), queue) }
  workers.each(&.run)
  until lock.synchronize { completed == count } && store.processing_queue_size(queue_name) == 0 && JoobQ::InFlight.count == 0
    raise "worker timeout" if Time.instant - started > 120.seconds
    sleep 1.millisecond
  end
end
elapsed = Time.instant - started
allocated = GC.stats.total_bytes - before
workers.each(&.terminate)
if mode != "worker"
  stored = store.redis.lrange(queue_name, 0, -1)
  raise "lost admission/promotion" unless stored.size == count
  stored.each do |raw|
    job = LegacyAllocationJob.from_json(raw.as(String))
    raise "duplicate/changed payload" if seen[job.index] || job.payload != payload
    raise "incorrect promoted state" if mode == "scheduler" && !job.enqueued?
    seen[job.index] = true
  end
end
raise "missing IDs" unless seen.all?
JoobQ::Latency.stop
scheduler.stop
puts({mode: mode, jobs: count, verified: seen.count(true), payload_bytes: payload.bytesize,
      workers: ENV.fetch("CRYSTAL_WORKERS", "4"), tls: true, appendfsync: "always",
      compiler: Crystal::VERSION, redis: store.redis.info("server")["redis_version"],
      elapsed_seconds: elapsed.total_seconds, jobs_per_second: count / elapsed.total_seconds,
      allocated_bytes_per_job: allocated / count, handler_executions: completed}.to_json)
store.close
