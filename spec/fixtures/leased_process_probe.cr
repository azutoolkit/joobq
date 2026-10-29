require "../../src/joobq"

{% unless flag?(:preview_mt) && !flag?(:execution_context) %}
  Fiber::ExecutionContext.default.resize(ENV.fetch("CRYSTAL_WORKERS", "4").to_i)
{% end %}
store = JoobQ::RedisStore.new(url: ENV.fetch("JOOBQ_SPEC_TLS_REDIS_URL"), ca_file: ENV.fetch("JOOBQ_SPEC_TLS_CA_FILE"),
  pool_size: 8, operation_timeout: 1.second)
namespace = ENV.fetch("PROBE_NAMESPACE")
count = ENV.fetch("PROBE_COUNT", "20").to_i
runtime = JoobQ::Delivery::Runtime.new(store, namespace, capacity: ENV.fetch("PROBE_CAPACITY", "4").to_i,
  lease: 600.milliseconds, poll: 5.milliseconds, repair_every: 20.milliseconds,
  batch_size: ENV.fetch("PROBE_BATCH_SIZE", "1").to_i)
ledger = runtime.register("work") do |payload, context|
  begin
    # An example external-effect receipt: replay is allowed, duplicate effects
    # are not. A real external service must honor this same idempotency key.
    store.redis.sadd("joobq:v1:#{namespace}:effects", context.idempotency_key)
    File.write(ENV.fetch("PROBE_STARTED"), "started") if ENV["PROBE_STARTED"]?
    sleep ENV.fetch("PROBE_WORK_MS", "0").to_i.milliseconds
    context.check!
    JoobQ::Delivery::Outcome.new
  rescue Redis::Error
    JoobQ::Delivery::Outcome.retry(100.milliseconds)
  end
end
case ARGV.first?
when "seed"
  count.times do |i|
    raise "admission failed" unless runtime.admit("work", "job-#{i}", "payload-#{i}").code.accepted?
  end
when "worker"
  report = runtime.serve(100.milliseconds)
  exit(report.clean ? 0 : 3)
when "inspect"
  entries = Array.new(count) { |i| ledger.resolve("job-#{i}") || raise "lost admitted job" }
  puts({completed: entries.count(&.state.completed?), attempts: entries.sum(&.attempt),
        effects: store.redis.scard("joobq:v1:#{namespace}:effects")}.to_json)
else
  raise "expected seed, worker or inspect"
end
