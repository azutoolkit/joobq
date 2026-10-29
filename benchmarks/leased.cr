require "../src/joobq"

{% unless flag?(:preview_mt) && !flag?(:execution_context) %}
  Fiber::ExecutionContext.default.resize(ENV.fetch("CRYSTAL_WORKERS", "4").to_i)
{% end %}
optimized = ENV.fetch("BENCH_PROTOCOL", "atomic") == "atomic"
count = ENV.fetch("BENCH_JOBS", "5000").to_i
capacity = ENV.fetch("BENCH_CAPACITY", "16").to_i
batch_size = ENV.fetch("BENCH_BATCH_SIZE", "1").to_i
payload_bytes = ENV.fetch("BENCH_PAYLOAD_BYTES", "1024").to_i
raise "BENCH_PAYLOAD_BYTES must be 1..16384" unless 1 <= payload_bytes <= 16384
producers = ENV.fetch("BENCH_PRODUCERS", "1").to_i
raise "BENCH_PRODUCERS must be 1..128" unless 1 <= producers <= 128
timeout = ENV.fetch("BENCH_TIMEOUT", "120").to_i.seconds
raise "BENCH_JOBS must be 1..1000000" unless 1 <= count <= 1_000_000
url = ENV.fetch("JOOBQ_SPEC_TLS_REDIS_URL")
store = JoobQ::RedisStore.new(url: url, ca_file: ENV.fetch("JOOBQ_SPEC_TLS_CA_FILE"), pool_size: capacity + 8)
runtime = JoobQ::Delivery::Runtime.new(store, "benchmark-#{UUID.random}", capacity: capacity,
  poll: 1.millisecond, repair_every: 1.second, max_records: count, optimized_delivery: optimized, batch_size: batch_size)
executions = Atomic(Int64).new(0_i64)
ledger = runtime.register("work") do |payload, context|
  executions.add(1_i64)
  JoobQ::Delivery::Outcome.new
end
payload = "x" * payload_bytes
admission_ms = [] of Float64
allocated_before = GC.stats.total_bytes
started = Time.instant
runtime.start
sequence = Atomic(Int32).new(0)
latency_lock = Sync::Mutex.new
done = Channel(Exception?).new(producers)
producers.times do
  spawn do
    loop do
      i = sequence.add(batch_size)
      break if i >= count
      before = Time.instant
      size = Math.min(batch_size, count - i)
      if batch_size == 1
        receipt = runtime.admit("work", "job-#{i}", payload)
        raise "admission not confirmed: #{receipt.code}" unless receipt.code.accepted?
      else
        requests = Array.new(size) { |offset| {"job-#{i + offset}", payload} }
        receipts = runtime.admit_many("work", requests)
        raise "batch admission not confirmed" unless receipts.all?(&.code.accepted?)
      end
      latency = (Time.instant - before).total_milliseconds
      latency_lock.synchronize { size.times { admission_ms << latency } }
    end
    done.send(nil)
  rescue ex
    done.send(ex)
  end
end
producers.times do
  error = done.receive
  raise error if error
end
# Reconciliation uses every accepted logical ID, not attempt or enqueue counts.
deadline = started + timeout
settled = 0
admission_seconds = (Time.instant - started).total_seconds
(0...count).each_slice(batch_size) do |indices|
  ids = indices.map { |i| "job-#{i}" }
  loop do
    receipts = batch_size == 1 ? [ledger.resolve(ids[0])] : ledger.resolve_many(ids)
    raise "accepted ID missing" if receipts.any?(&.nil?)
    raise "terminal failure" if receipts.any? { |r| r.try(&.state.dead?) }
    if receipts.all? { |r| r.try(&.state.completed?) }
      raise "unexpected redelivery" unless receipts.all? { |r| r.try(&.attempt) == 1 }
      settled += receipts.size
      break
    end
    raise "benchmark did not drain before deadline" if Time.instant >= deadline
    sleep 1.millisecond
  end
end
raise "handler execution count differs" unless executions.get == count
elapsed = Time.instant - started
drain = runtime.stop(5.seconds)
raise "runtime did not drain" unless drain.clean
admission_ms.sort!
manifest = {
  protocol: optimized ? "atomic" : "cas", compiler: Crystal::VERSION, redis: store.redis.info("server")["redis_version"],
  workers: ENV.fetch("CRYSTAL_WORKERS", "4"), capacity: capacity, producers: producers, batch_size: batch_size,
  tls: true, appendfsync: "always", payload_bytes: payload.bytesize,
  admission_seconds: admission_seconds, handler_executions: executions.get,
  redis_cpu: store.redis.info("cpu"), redis_commands: store.redis.info("commandstats"),
  accepted: count, confirmed_completed: settled, elapsed_seconds: elapsed.total_seconds,
  settled_per_second: settled / elapsed.total_seconds,
  admission_p50_ms: admission_ms[(count * 0.50).to_i.clamp(0, count - 1)],
  admission_p99_ms: admission_ms[(count * 0.99).to_i.clamp(0, count - 1)],
  gc_heap_bytes: GC.stats.heap_size, gc_total_bytes: GC.stats.total_bytes,
  allocated_bytes_per_job: (GC.stats.total_bytes - allocated_before) / count,
  meets_million_per_minute: settled / elapsed.total_seconds >= 1_000_000.0 / 60,
  million_completed_within_minute: settled >= 1_000_000 && elapsed <= 1.minute,
  meets_35000_settled_per_second: settled / elapsed.total_seconds >= 35_000,
  duration_gate_met: elapsed >= 30.minutes,
  metrics: runtime.metrics.prometheus,
}
puts manifest.to_json
store.close
