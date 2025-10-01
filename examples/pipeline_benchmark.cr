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

# Test 1: Pipeline vs Individual Operations
puts "📊 Benchmark 1: Pipeline vs Individual Operations"
puts "-" * 50

JoobQ.configure do
  # Test with pipeline optimization DISABLED
  enable_pipeline_optimization = false
  queue "benchmark_queue", 5, BenchmarkJob
end

# Warmup
BENCHMARK_CONFIG[:warmup_iterations].times do
  JoobQ.config.error_monitor.clear_redis_errors
end

# Individual operations benchmark
individual_times = [] of Float64
BENCHMARK_CONFIG[:metrics_iterations].times do
  start_time = Time.monotonic

  # Simulate individual error operations
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
    JoobQ.config.error_monitor.record_error(error_context)
  end

  individual_times << (Time.monotonic - start_time).total_milliseconds
end

individual_avg = individual_times.sum / individual_times.size
individual_min = individual_times.min
individual_max = individual_times.max

puts "Individual Operations:"
puts "  Average: #{individual_avg.round(2)}ms"
puts "  Min: #{individual_min.round(2)}ms"
puts "  Max: #{individual_max.round(2)}ms"
puts "  Operations: #{BENCHMARK_CONFIG[:error_count]} errors"
puts ""

# Clear Redis for pipeline test
JoobQ.config.error_monitor.clear_redis_errors

# Configure with pipeline optimization ENABLED
JoobQ.configure do
  enable_pipeline_optimization = true
  pipeline_batch_size = 100
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

# Performance comparison
improvement = individual_avg / pipeline_avg
puts "🎯 Performance Results:"
puts "  Speed improvement: #{improvement.round(2)}x faster"
puts "  Time reduction: #{(100 - (pipeline_avg / individual_avg * 100)).round(1)}%"
puts ""

# Test 2: Job Enqueuing Benchmark
puts "📊 Benchmark 2: Job Enqueuing Performance"
puts "-" * 50

# Individual job enqueuing
individual_job_times = [] of Float64
BENCHMARK_CONFIG[:metrics_iterations].times do
  start_time = Time.monotonic

  BENCHMARK_CONFIG[:job_count].times do |i|
    job = BenchmarkJob.new("individual_job_#{i}")
    JoobQ.queues["benchmark_queue"].add(job)
  end

  individual_job_times << (Time.monotonic - start_time).total_milliseconds
end

individual_job_avg = individual_job_times.sum / individual_job_times.size

puts "Individual Job Enqueuing:"
puts "  Average: #{individual_job_avg.round(2)}ms"
puts "  Jobs: #{BENCHMARK_CONFIG[:job_count]}"
puts ""

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

job_improvement = individual_job_avg / batch_job_avg
puts "🎯 Job Enqueuing Results:"
puts "  Speed improvement: #{job_improvement.round(2)}x faster"
puts "  Time reduction: #{(100 - (batch_job_avg / individual_job_avg * 100)).round(1)}%"
puts ""

# Test 3: Queue Metrics Benchmark
puts "📊 Benchmark 3: Queue Metrics Performance"
puts "-" * 50

# Individual metrics collection
individual_metrics_times = [] of Float64
BENCHMARK_CONFIG[:metrics_iterations].times do
  start_time = Time.monotonic

  metrics = JoobQ.store.as(JoobQ::RedisStore).get_queue_metrics("benchmark_queue")

  individual_metrics_times << (Time.monotonic - start_time).total_milliseconds
end

individual_metrics_avg = individual_metrics_times.sum / individual_metrics_times.size

puts "Individual Metrics Collection:"
puts "  Average: #{individual_metrics_avg.round(2)}ms"
puts "  Queues: 1"
puts ""

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

metrics_improvement = individual_metrics_avg / batch_metrics_avg
puts "🎯 Metrics Collection Results:"
puts "  Speed improvement: #{metrics_improvement.round(2)}x faster"
puts "  Time reduction: #{(100 - (batch_metrics_avg / individual_metrics_avg * 100)).round(1)}%"
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
puts "Error Monitoring: #{improvement.round(2)}x faster"
puts "Job Enqueuing: #{job_improvement.round(2)}x faster"
puts "Metrics Collection: #{metrics_improvement.round(2)}x faster"
puts ""

overall_improvement = (improvement + job_improvement + metrics_improvement) / 3
puts "Average Performance Improvement: #{overall_improvement.round(2)}x faster"
puts ""

puts "✅ Benchmark completed successfully!"
puts ""
puts "Recommendations:"
puts "  • Enable pipeline optimization for production workloads"
puts "  • Tune batch sizes based on your specific use case"
puts "  • Monitor pipeline statistics for optimization opportunities"
puts "  • Use batch operations whenever possible for maximum performance"
