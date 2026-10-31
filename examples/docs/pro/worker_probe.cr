require "joobq_pro"

# Run separately, after production_worker.cr is ready, against the same Redis.
client = JoobQPro::Workflows::Client.new
id = client.start("orders", 42_i64)
result = client.result(id, timeout: 10.seconds)
raise "Unexpected worker result" unless result["process"].as_s == "Processed order 42"
puts result["process"].as_s
