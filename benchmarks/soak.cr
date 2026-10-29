require "../src/joobq"

# Only accepts the isolated harness's TLS fixture. This probe injects CLIENT
# PAUSE; never point it at an application/shared Redis.
Fiber::ExecutionContext.default.resize(ENV.fetch("CRYSTAL_WORKERS", "4").to_i)
seconds = ENV.fetch("SOAK_SECONDS", "60").to_i
rate = ENV.fetch("SOAK_RATE", "50").to_i
limit = ENV.fetch("SOAK_MAX_RECORDS", "100000").to_i
raise "positive duration/rate required" unless seconds > 0 && rate > 0
count = seconds.to_i64 * rate
raise "planned receipts exceed SOAK_MAX_RECORDS; retention is not automatic" unless count <= limit
capacity = ENV.fetch("SOAK_CAPACITY", "8").to_i
store = JoobQ::RedisStore.new(url: ENV.fetch("JOOBQ_SPEC_TLS_REDIS_URL"),
  ca_file: ENV.fetch("JOOBQ_SPEC_TLS_CA_FILE"), pool_size: capacity + 8, operation_timeout: 200.milliseconds)
namespace = "soak-#{UUID.random}"
runtime = JoobQ::Delivery::Runtime.new(store, namespace, capacity: capacity,
  lease: 1.second, poll: 2.milliseconds, repair_every: 100.milliseconds, max_records: limit)
effects = "joobq:v1:#{namespace}:effects"
ledger = runtime.register("work") do |payload, context|
  begin
    context.check!
    store.redis.sadd(effects, context.idempotency_key)
    JoobQ::Delivery::Outcome.new
  rescue Redis::Error | IO::Error
    JoobQ::Delivery::Outcome.retry(100.milliseconds)
  end
end
runtime.start
started = Time.instant
finish_faults = Channel(Nil).new(1)
fault_done = Channel(Nil).new(1)
faults = Atomic(Int32).new(0)
spawn do
  loop do
    select
    when finish_faults.receive
      break
    when timeout(10.seconds)
      begin
        store.redis.command(["CLIENT", "PAUSE", "500", "ALL"])
        faults.add(1)
      rescue Redis::Error | IO::Error
        # The pause command can have an unknown outcome too.
      end
    end
  end
ensure
  fault_done.send(nil)
end
payload = "x" * 1024
count.times do |i|
  target = started + (i.to_f64 / rate).seconds
  sleep target - Time.instant if Time.instant < target
  admission_deadline = Time.instant + 10.seconds
  loop do
    result = runtime.admit("work", "job-#{i}", payload)
    break if result.code.accepted?
    raise "admission rejected: #{result.reason}" if result.code.rejected?
    raise "admission remained unknown" if Time.instant >= admission_deadline
    sleep 20.milliseconds # identity-safe replay of this one logical admission
  end
end
finish_faults.send(nil)
fault_done.receive
settled = 0_i64
attempts = 0_i64
deadline = Time.instant + 30.seconds
count.times do |i|
  loop do
    record = ledger.resolve("job-#{i}") || raise "accepted identity lost"
    if record.state.completed?
      settled += 1
      attempts += record.attempt
      break
    end
    raise "dead or undrained delivery" if record.state.dead? || Time.instant >= deadline
    sleep 10.milliseconds
  end
end
elapsed = Time.instant - started
drain = runtime.stop(5.seconds)
raise "unclean drain" unless drain.clean
actual_effects = store.redis.scard(effects)
raise "effect conservation failed" unless actual_effects == count
puts({kind: "bounded_soak", compiler: Crystal::VERSION, redis: store.redis.info("server")["redis_version"],
      tls: true, appendfsync: "always", requested_seconds: seconds, elapsed_seconds: elapsed.total_seconds,
      offered_per_second: rate, accepted: count, completed: settled, distinct_effects: actual_effects,
      attempts: attempts, injected_pauses: faults.get, gc_heap_bytes: GC.stats.heap_size,
      retained_records: store.redis.hlen(ledger.records_key), four_hour_duration_met: elapsed >= 4.hours,
      metrics: runtime.prometheus}.to_json)
store.close
