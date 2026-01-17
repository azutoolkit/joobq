---
description: Run JoobQ performance benchmarks
---

# Run Benchmarks

Execute performance benchmarks for JoobQ.

## Quick Benchmark

```crystal
require "benchmark"
require "joobq"

JoobQ.configure do
  queue "bench", 10, BenchJob
end

Benchmark.ips do |x|
  x.report("enqueue") { BenchJob.enqueue(data: "test") }
end
```

## Throughput Test

```crystal
total_jobs = 10_000
start_time = Time.monotonic

total_jobs.times { |i| BenchJob.enqueue(data: "test#{i}") }

queue = JoobQ["bench"]
queue.start

while queue.size > 0
  sleep 0.1.seconds
end

duration = Time.monotonic - start_time
puts "Processed #{total_jobs} jobs in #{duration.total_seconds}s"
puts "Throughput: #{(total_jobs / duration.total_seconds).round(2)} jobs/sec"

queue.stop!
```

## Benchmark Files

Existing benchmarks in `playground/`:
- `playground/bench.cr` - Main benchmark
- `playground/pipeline_benchmark.cr` - Pipeline performance
- `playground/pipeline_test.cr` - Pipeline testing

## Running Benchmarks

```bash
# Run benchmark file
crystal run playground/bench.cr

# Build optimized and run
crystal build --release playground/bench.cr -o bench
./bench
```

## Expected Performance

- Single enqueue: ~35,000 ops/sec
- Batch enqueue: Higher with batching
- Processing: Depends on job complexity and worker count

## Redis Performance Tips

1. Use pipelining for bulk operations
2. Increase `worker_batch_size` for throughput
3. Tune `pipeline_batch_size` for your workload
4. Monitor Redis memory and connections
