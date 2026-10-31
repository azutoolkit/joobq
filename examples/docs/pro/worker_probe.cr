require "joobq_pro"

# Run separately, after production_worker.cr is ready, against the same Redis.
client = JoobQPro::Workflows::Client.new
# A fresh canary each invocation; retries within this invocation reuse its ID.
request_id = UUID.random.to_s
id, created = client.try_start("orders", 42_i64, id: request_id)
raise "Expected a new run" unless created
repeated_id, repeated = client.try_start("orders", 42_i64, id: id)
raise "Repeated start created another run" if repeated || repeated_id != id
result = client.result(id, timeout: 10.seconds)
raise "Unexpected worker result" unless result["process"].as_s == "Processed order 42"
puts result["process"].as_s
