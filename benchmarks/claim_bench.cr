require "../src/joobq"

# Ad-hoc benchmark for the claim path: idle behaviour, single-job pick-up latency, and drain throughput.
# Run against a throwaway Redis: REDIS_HOST/REDIS_PORT. Not part of the suite.
{% unless flag?(:preview_mt) && !flag?(:execution_context) %}
  Fiber::ExecutionContext.default.resize(ENV.fetch("CRYSTAL_WORKERS", "4").to_i)
{% end %}
Log.setup(:error)

module Bench
  class Job
    include JoobQ::Job
    getter n : Int32

    def initialize(@n, @queue : String)
    end

    def perform
    end
  end
end

store = JoobQ::RedisStore.new(host: ENV.fetch("REDIS_HOST", "localhost"), port: ENV.fetch("REDIS_PORT", "6379").to_i, pool_size: 64)
JoobQ.config.store = store
JoobQ.config.worker_batch_size = ENV.fetch("BATCH", "10").to_i
workers = ENV.fetch("WORKERS", "4").to_i
mode = ENV.fetch("BENCH", "throughput")

def commandstats(store)
  raw = store.redis.command(["INFO", "commandstats"]).as(String)
  calls = 0_i64
  raw.each_line do |line|
    if m = line.match(/cmdstat_(\w+):calls=(\d+)/)
      calls += m[2].to_i64 if %w[lmove blmove llen rpush lpush lrem zadd].includes?(m[1].downcase)
    end
  end
  calls
end

case mode
when "idle"
  qn = "bench-idle-#{UUID.random}"
  completed = Atomic(Int32).new(0)
  queue = JoobQ::Queue(Bench::Job).new(qn, workers, store: store, handler: ->(j : Bench::Job) { completed.add(1); nil })
  queue.start
  sleep 1.second # let it settle
  clients = store.redis.command(["INFO", "clients"]).as(String).match(/connected_clients:(\d+)/).not_nil![1]
  before = commandstats(store)
  window = 3.0
  sleep window.seconds
  after = commandstats(store)
  queue.stop!
  puts "IDLE workers=#{workers} batch=#{JoobQ.config.worker_batch_size} connected_clients=#{clients} claim_cmds_per_s=#{((after - before) / window).round(1)}"
when "latency"
  samples = ENV.fetch("SAMPLES", "20").to_i
  qn = "bench-lat-#{UUID.random}"
  got = Channel(Time::Instant).new(samples)
  queue = JoobQ::Queue(Bench::Job).new(qn, workers, store: store, handler: ->(j : Bench::Job) { got.send(Time.instant); nil })
  queue.start
  sleep 500.milliseconds
  lat = [] of Float64
  samples.times do |i|
    t0 = Time.instant
    store.enqueue(Bench::Job.new(i, qn))
    done = got.receive
    lat << (done - t0).total_milliseconds
    sleep 150.milliseconds # ensure the queue is idle between samples
  end
  queue.stop!
  lat.sort!
  puts "LATENCY workers=#{workers} samples=#{samples} p50_ms=#{lat[lat.size // 2].round(3)} p99_ms=#{lat[(lat.size * 99 // 100)].round(3)} max_ms=#{lat.last.round(3)}"
when "throughput"
  count = ENV.fetch("JOBS", "20000").to_i
  qn = "bench-thru-#{UUID.random}"
  completed = Atomic(Int32).new(0)
  done = Channel(Nil).new
  queue = JoobQ::Queue(Bench::Job).new(qn, workers, store: store, handler: ->(j : Bench::Job) {
    done.send(nil) if completed.add(1) + 1 == count
    nil
  })
  raws = Array.new(count) { |i| Bench::Job.new(i, qn).to_json }
  jobs = raws.map { |r| Bench::Job.from_json(r).as(JoobQ::Job) }
  store.enqueue_batch(jobs)
  t0 = Time.instant
  queue.start
  done.receive
  elapsed = (Time.instant - t0).total_seconds
  queue.stop!
  puts "THROUGHPUT workers=#{workers} batch=#{JoobQ.config.worker_batch_size} jobs=#{count} elapsed_s=#{elapsed.round(3)} jobs_per_s=#{(count / elapsed).round(0)}"
end
