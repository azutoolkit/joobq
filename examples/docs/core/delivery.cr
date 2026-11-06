require "joobq"

JoobQ.configure { |config| config.rest_api_enabled = false }

# Checks appendonly=yes, appendfsync=always and maxmemory-policy=noeviction first.
runtime = JoobQ::Delivery::Runtime.new(JoobQ::RedisStore.instance, "billing", capacity: 2)
runtime.register("invoices") do |payload, context|
  puts "Charged invoice #{payload}, idempotency key #{context.idempotency_key}"
  JoobQ::Delivery::Outcome.new
end

first = runtime.admit("invoices", "invoice-1001", "1001")
again = runtime.admit("invoices", "invoice-1001", "1001")
puts "First admission: #{first.code}, same request again: #{again.code}, same id: #{first.id == again.id}"
runtime.start
sleep 1.second
puts "Drained cleanly: #{runtime.stop(5.seconds).clean}"
