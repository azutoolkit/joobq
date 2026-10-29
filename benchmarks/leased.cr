require "../src/joobq"

Fiber::ExecutionContext.default.resize(ENV.fetch("CRYSTAL_WORKERS", "4").to_i)
optimized = ENV.fetch("BENCH_PROTOCOL", "atomic") == "atomic"
count = ENV.fetch("BENCH_JOBS", "5000").to_i
capacity = ENV.fetch("BENCH_CAPACITY", "16").to_i
producers = ENV.fetch("BENCH_PRODUCERS", "1").to_i
raise "BENCH_PRODUCERS must be 1..128" unless 1 <= producers <= 128
timeout = ENV.fetch("BENCH_TIMEOUT", "120").to_i.seconds
raise "BENCH_JOBS must be 1..1000000" unless 1 <= count <= 1_000_000
url = ENV.fetch("JOOBQ_SPEC_TLS_REDIS_URL")
store = JoobQ::RedisStore.new(url: url, ca_file: ENV.fetch("JOOBQ_SPEC_TLS_CA_FILE"), pool_size: capacity + 8)
runtime = JoobQ::Delivery::Runtime.new(store, "benchmark-#{UUID.random}", capacity: capacity,
  poll: 1.millisecond, repair_every: 1.second, max_records: count, optimized_delivery: optimized)
ledger = runtime.register("work") { |payload, context| JoobQ::Delivery::Outcome.new }
payload = "x" * 1024
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
      i = sequence.add(1)
      break if i >= count
      before = Time.instant
      receipt = runtime.admit("work", "job-#{i}", payload)
      raise "admission not confirmed: #{receipt.code}" unless receipt.code.accepted?
      latency = (Time.instant - before).total_milliseconds
      latency_lock.synchronize { admission_ms << latency }
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
count.times do |i|
  loop do
    receipt = ledger.resolve("job-#{i}") || raise "accepted ID missing"
    if receipt.state.completed?
      settled += 1
      break
    end
    raise "terminal failure" if receipt.state.dead?
    raise "benchmark did not drain before deadline" if Time.instant >= deadline
    sleep 1.millisecond
  end
end
elapsed = Time.instant - started
drain = runtime.stop(5.seconds)
raise "runtime did not drain" unless drain.clean
admission_ms.sort!
manifest = {
  protocol: optimized ? "atomic" : "cas", compiler: Crystal::VERSION, redis: store.redis.info("server")["redis_version"],
  workers: ENV.fetch("CRYSTAL_WORKERS", "4"), capacity: capacity, producers: producers,
  tls: true, appendfsync: "always", payload_bytes: payload.bytesize,
  accepted: count, confirmed_completed: settled, elapsed_seconds: elapsed.total_seconds,
  settled_per_second: settled / elapsed.total_seconds,
  admission_p50_ms: admission_ms[(count * 0.50).to_i.clamp(0, count - 1)],
  admission_p99_ms: admission_ms[(count * 0.99).to_i.clamp(0, count - 1)],
  gc_heap_bytes: GC.stats.heap_size, gc_total_bytes: GC.stats.total_bytes,
  allocated_bytes_per_job: (GC.stats.total_bytes - allocated_before) / count,
  meets_35000_settled_per_second: settled / elapsed.total_seconds >= 35_000,
  duration_gate_met: elapsed >= 30.minutes,
  metrics: runtime.metrics.prometheus,
}
puts manifest.to_json
store.close
