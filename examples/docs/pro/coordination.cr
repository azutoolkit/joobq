require "joobq_pro"

JoobQ.configure { |config| config.rest_api_enabled = false }
store = JoobQ::RedisStore.instance
runtime = JoobQ::Delivery::Runtime.new(store, "docs-#{UUID.random}", capacity: 2, repair_every: 20.milliseconds)
runtime.register("orders") { |_, context| context.check!; JoobQ::Delivery::Outcome.new }
batches = JoobQPro::Durable::Batches.new(runtime)
unique = JoobQPro::Durable::UniqueJobs.new(runtime)

begin
  batch = batches.create(description: "Documentation batch")
  batches.add(batch.id, "orders", "order-42", "42")
  batches.seal(batch.id)

  admitted = unique.admit("orders", "invoice-42", "request-42", "42", mode: JoobQPro::UniquenessMode::WhileLocked)
  raise "Unique admission failed" unless admitted.code.accepted?
  duplicate = unique.admit("orders", "invoice-42", "request-43", "42", mode: JoobQPro::UniquenessMode::WhileLocked)
  raise "Duplicate was admitted" unless duplicate.code.duplicate?
  raise "Stale owner released reservation" if unique.release("orders", "invoice-42", "wrong-owner")

  runtime.start
  deadline = Time.instant + 10.seconds
  until batches.snapshot(batch.id).complete?
    raise "Batch did not complete" if Time.instant >= deadline
    sleep 20.milliseconds
  end
  raise "Batch did not record completion" unless batches.snapshot(batch.id).completed == 1
  owner = admitted.owner || raise "Missing unique owner"
  raise "Owner could not release reservation" unless unique.release("orders", "invoice-42", owner)

  limit = JoobQPro::RateLimit.new(count: 2, period: 1.minute)
  key = "docs-#{UUID.random}"
  results = Channel(Bool).new(8)
  8.times do
    spawn { results.send(JoobQPro::RateLimiter.reserve(key, limit, store.redis).allowed) }
  end
  permitted = 0
  8.times do
    select
    when allowed = results.receive
      permitted += 1 if allowed
    when timeout(5.seconds)
      raise "Rate reservation timed out"
    end
  end
  raise "Shared limit exceeded" unless permitted == 2
ensure
  drained = runtime.stop(5.seconds).clean
  JoobQPro.shutdown
  JoobQ.shutdown
  raise "Delivery did not drain" unless drained
end
puts "PASS batch uniqueness concurrent rate limit"
