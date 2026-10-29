require "../src/joobq"
{% unless flag?(:preview_mt) && !flag?(:execution_context) %}
  Fiber::ExecutionContext.default.resize(2)
{% end %}
count = 10000
payload = "x" * 1024
record = JoobQ::Delivery::Record.new("id", payload, Digest::SHA256.hexdigest(payload))
raw = record.to_json
results = {} of String => Float64
before = GC.stats.total_bytes
count.times { JoobQ::Delivery::Record.from_json(raw).validate! }
results["decode_validate_bytes_per_record"] = (GC.stats.total_bytes - before) / count
before = GC.stats.total_bytes
count.times { record.to_json }
results["default_encode_bytes_per_record"] = (GC.stats.total_bytes - before) / count
before = GC.stats.total_bytes
count.times { Digest::SHA256.hexdigest(payload) }
results["sha256_bytes_per_payload"] = (GC.stats.total_bytes - before) / count
before = GC.stats.total_bytes
count.times { record.encoded }
results["presized_encode_bytes_per_record"] = (GC.stats.total_bytes - before) / count
before = GC.stats.total_bytes
count.times { JoobQ::Delivery::Checksum.matches?(payload, record.digest) }
results["checksum_validation_bytes_per_payload"] = (GC.stats.total_bytes - before) / count
puts({iterations: count, payload_bytes: payload.bytesize, compiler: Crystal::VERSION, allocated_bytes: results}.to_json)
