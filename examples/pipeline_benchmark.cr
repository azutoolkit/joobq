#!/usr/bin/env crystal

require "../src/joobq"
require "benchmark"

# Comprehensive benchmark script for Redis pipeline optimizations
class BenchmarkJob
  include JoobQ::Job
  include JSON::Serializable

  getter message : String
  getter processing_time : Float64

  def initialize(@message : String = "benchmark", @processing_time : Float64 = 0.001)
  end

  def perform
    sleep(@processing_time.seconds)
  end
end

# Benchmark configuration
BENCHMARK_CONFIG = {
  job_count: 1000,
  error_count: 500,
  metrics_iterations: 100,
  warmup_iterations: 10
}

puts "🚀 JoobQ Redis Pipeline Benchmark"
puts "=" * 50
puts "Configuration:"
puts "  Jobs: #{BENCHMARK_CONFIG[:job_count]}"
puts "  Errors: #{BENCHMARK_CONFIG[:error_count]}"
puts "  Metrics iterations: #{BENCHMARK_CONFIG[:metrics_iterations]}"
puts "  Warmup iterations: #{BENCHMARK_CONFIG[:warmup_iterations]}"
puts ""

# Test 1: Pipeline Performance Testing
puts "📊 Benchmark 1: Pipeline Performance Testing"
puts "-" * 50

JoobQ.configure do
  # Pipeline optimization is always enabled
  pipeline_batch_size = 50
  queue "benchmark_queue", 5, BenchmarkJob
end

# Warmup
BENCHMARK_CONFIG[:warmup_iterations].times do
  JoobQ.config.error_monitor.clear_redis_errors
end

# Pipeline operations benchmark
pipeline_times = [] of Float64
BENCHMARK_CONFIG[:metrics_iterations].times do
  start_time = Time.monotonic

  # Simulate batch error operations
  error_contexts = [] of JoobQ::ErrorContext
  BENCHMARK_CONFIG[:error_count].times do |i|
    error_context = JoobQ::ErrorContext.new(
      job_id: "benchmark_job_#{i}",
      queue_name: "benchmark_queue",
      worker_id: "benchmark_worker",
      job_type: "BenchmarkJob",
      error_type: "benchmark_error",
      error_message: "Benchmark error #{i}",
      error_class: "BenchmarkError",
      backtrace: ["line 1", "line 2"],
      retry_count: 0
    )
    error_contexts << error_context
  end

  JoobQ.config.error_monitor.store_errors_batch(error_contexts)

  pipeline_times << (Time.monotonic - start_time).total_milliseconds
end

pipeline_avg = pipeline_times.sum / pipeline_times.size
pipeline_min = pipeline_times.min
pipeline_max = pipeline_times.max

puts "Pipeline Operations:"
puts "  Average: #{pipeline_avg.round(2)}ms"
puts "  Min: #{pipeline_min.round(2)}ms"
puts "  Max: #{pipeline_max.round(2)}ms"
puts "  Operations: #{BENCHMARK_CONFIG[:error_count]} errors in batches"
puts ""

# Test 2: Job Enqueuing Benchmark
puts "📊 Benchmark 2: Job Enqueuing Performance"
puts "-" * 50

# Batch job enqueuing
batch_job_times = [] of Float64
BENCHMARK_CONFIG[:metrics_iterations].times do
  start_time = Time.monotonic

  jobs = [] of BenchmarkJob
  BENCHMARK_CONFIG[:job_count].times do |i|
    jobs << BenchmarkJob.new("batch_job_#{i}")
  end

  JoobQ.queues["benchmark_queue"].add_batch(jobs)

  batch_job_times << (Time.monotonic - start_time).total_milliseconds
end

batch_job_avg = batch_job_times.sum / batch_job_times.size

puts "Batch Job Enqueuing:"
puts "  Average: #{batch_job_avg.round(2)}ms"
puts "  Jobs: #{BENCHMARK_CONFIG[:job_count]} in batches"
puts ""

# Test 3: Queue Metrics Benchmark
puts "📊 Benchmark 3: Queue Metrics Performance"
puts "-" * 50

# Batch metrics collection
batch_metrics_times = [] of Float64
BENCHMARK_CONFIG[:metrics_iterations].times do
  start_time = Time.monotonic

  all_metrics = JoobQ.store.as(JoobQ::RedisStore).get_all_queue_metrics

  batch_metrics_times << (Time.monotonic - start_time).total_milliseconds
end

batch_metrics_avg = batch_metrics_times.sum / batch_metrics_times.size

puts "Batch Metrics Collection:"
puts "  Average: #{batch_metrics_avg.round(2)}ms"
puts "  Queues: #{JoobQ.config.queues.keys.size}"
puts ""

# Test 4: Pipeline Statistics
puts "📊 Benchmark 4: Pipeline Statistics"
puts "-" * 50

pipeline_stats = JoobQ::RedisStore.pipeline_stats
puts "Pipeline Performance Stats:"
puts "  Total pipeline calls: #{pipeline_stats.total_pipeline_calls}"
puts "  Total commands batched: #{pipeline_stats.total_commands_batched}"
puts "  Average batch size: #{pipeline_stats.average_batch_size.round(2)}"
puts "  Pipeline failures: #{pipeline_stats.pipeline_failures}"
puts "  Success rate: #{((pipeline_stats.total_pipeline_calls - pipeline_stats.pipeline_failures).to_f / pipeline_stats.total_pipeline_calls * 100).round(1)}%"
puts ""

# Test 5: Memory Usage Analysis
puts "📊 Benchmark 5: Memory Usage Analysis"
puts "-" * 50

# This is a simplified memory analysis
puts "Memory Considerations:"
puts "  Pipeline batch size: #{JoobQ.config.pipeline_batch_size}"
puts "  Max commands per pipeline: #{JoobQ.config.pipeline_max_commands}"
puts "  Pipeline timeout: #{JoobQ.config.pipeline_timeout}s"
puts ""

# Summary
puts "🎯 Overall Performance Summary"
puts "=" * 50
puts "Pipeline operations are always enabled for optimal performance"
puts ""

puts "✅ Benchmark completed successfully!"
puts ""
puts "Recommendations:"
puts "  • Pipeline optimization is always enabled for optimal performance"
puts "  • Tune batch sizes based on your specific use case"
puts "  • Monitor pipeline statistics for optimization opportunities"
puts "  • Use batch operations whenever possible for maximum performance"
