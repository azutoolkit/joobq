#!/usr/bin/env crystal

require "../src/joobq"

# Test script to verify Redis pipeline optimizations
class TestJob
  include JoobQ::Job
  include JSON::Serializable

  getter message : String

  def initialize(@message : String = "test")
  end

  def perform
    puts "Processing job: #{message}"
    sleep(0.1.seconds) # Simulate some work
  end
end

# Configure JoobQ (pipeline optimization is always enabled)
JoobQ.configure do
  # Pipeline optimization settings
  pipeline_batch_size = 50
  pipeline_timeout = 1.0
  pipeline_max_commands = 500

  # Set up error monitoring
  error_monitoring do |monitor|
    monitor.alert_thresholds = {
      "error" => 5,
      "warn" => 20,
      "info" => 50
    }
    monitor.time_window = 2.minutes
    monitor.max_recent_errors = 50
  end

  # Define test queue
  queue "test_queue", 2, TestJob
end

puts "🚀 Testing Redis Pipeline Optimizations in JoobQ"
puts "=" * 50

# Test 1: Error monitoring pipeline
puts "\n1. Testing Error Monitoring Pipeline..."
error_contexts = [] of JoobQ::ErrorContext

# Create some test error contexts
5.times do |i|
  error_context = JoobQ::ErrorContext.new(
    job_id: "test_job_#{i}",
    queue_name: "test_queue",
    worker_id: "test_worker",
    job_type: "TestJob",
    error_type: "test_error",
    error_message: "Test error message #{i}",
    error_class: "TestError",
    backtrace: ["line 1", "line 2"],
    retry_count: 0,
    system_context: {"test" => "true"}
  )
  error_contexts << error_context
end

# Test individual error recording
start_time = Time.monotonic
error_contexts.each { |ctx| JoobQ.config.error_monitor.record_error(ctx) }
individual_time = Time.monotonic - start_time

puts "   Individual error recording: #{(individual_time.total_milliseconds).round(2)}ms"

# Test batch error recording
start_time = Time.monotonic
JoobQ.config.error_monitor.store_errors_batch(error_contexts)
batch_time = Time.monotonic - start_time

puts "   Batch error recording: #{(batch_time.total_milliseconds).round(2)}ms"
puts "   Performance improvement: #{(individual_time / batch_time).round(2)}x faster"

# Test 2: Job processing pipeline
puts "\n2. Testing Job Processing Pipeline..."

# Start the queue
JoobQ.queues["test_queue"].start

# Create some test jobs
test_jobs = [] of TestJob
10.times do |i|
  test_jobs << TestJob.new("batch_test_#{i}")
end

# Test individual job enqueuing
start_time = Time.monotonic
test_jobs.each { |job| JoobQ.queues["test_queue"].add(job) }
individual_enqueue_time = Time.monotonic - start_time

puts "   Individual job enqueuing: #{(individual_enqueue_time.total_milliseconds).round(2)}ms"

# Test batch job enqueuing
test_jobs_batch = [] of TestJob
10.times do |i|
  test_jobs_batch << TestJob.new("batch_test_2_#{i}")
end

start_time = Time.monotonic
JoobQ.queues["test_queue"].add_batch(test_jobs_batch)
batch_enqueue_time = Time.monotonic - start_time

puts "   Batch job enqueuing: #{(batch_enqueue_time.total_milliseconds).round(2)}ms"
puts "   Performance improvement: #{(individual_enqueue_time / batch_enqueue_time).round(2)}x faster"

# Test 3: Queue metrics pipeline
puts "\n3. Testing Queue Metrics Pipeline..."

# Test individual metrics collection
start_time = Time.monotonic
metrics = JoobQ.store.as(JoobQ::RedisStore).get_queue_metrics("test_queue")
individual_metrics_time = Time.monotonic - start_time

puts "   Individual metrics collection: #{(individual_metrics_time.total_milliseconds).round(2)}ms"
puts "   Queue metrics: size=#{metrics.queue_size}, processing=#{metrics.processing_size}, failed=#{metrics.failed_count}"

# Test batch metrics collection
start_time = Time.monotonic
all_metrics = JoobQ.store.as(JoobQ::RedisStore).get_all_queue_metrics
batch_metrics_time = Time.monotonic - start_time

puts "   Batch metrics collection: #{(batch_metrics_time.total_milliseconds).round(2)}ms"
puts "   All queue metrics collected: #{all_metrics.keys.join(", ")}"

# Test 4: Configuration verification
puts "\n4. Testing Configuration..."
puts "   Pipeline optimization: Always enabled"
puts "   Pipeline batch size: #{JoobQ.config.pipeline_batch_size}"
puts "   Pipeline timeout: #{JoobQ.config.pipeline_timeout}s"
puts "   Pipeline max commands: #{JoobQ.config.pipeline_max_commands}"

# Clean up
puts "\n5. Cleaning up..."
JoobQ.queues["test_queue"].stop!
JoobQ.config.error_monitor.clear_redis_errors

puts "\n✅ Pipeline optimization tests completed!"
puts "\nExpected improvements:"
puts "  - Error monitoring: 3-4x faster with pipelining"
puts "  - Job processing: 2-3x faster with batch operations"
puts "  - Queue metrics: 5-10x faster with batch collection"
puts "  - Scheduler operations: 5-10x faster for batch processing"
