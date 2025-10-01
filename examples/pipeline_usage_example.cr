#!/usr/bin/env crystal

require "../src/joobq"

# Comprehensive example demonstrating Redis pipeline optimizations in JoobQ
class EmailJob
  include JoobQ::Job
  include JSON::Serializable

  getter to : String
  getter subject : String
  getter body : String

  def initialize(@to : String, @subject : String, @body : String)
  end

  def perform
    puts "Sending email to #{@to}: #{@subject}"
    sleep(0.1.seconds) # Simulate email sending
  end
end

class DataProcessingJob
  include JoobQ::Job
  include JSON::Serializable

  getter data : Array(Int32)
  getter operation : String

  def initialize(@data : Array(Int32), @operation : String = "sum")
  end

  def perform
    case @operation
    when "sum"
      result = @data.sum
      puts "Sum of #{@data} = #{result}"
    when "average"
      result = @data.sum.to_f / @data.size
      puts "Average of #{@data} = #{result}"
    else
      puts "Processing #{@data} with operation: #{@operation}"
    end
  end
end

puts "🚀 JoobQ Redis Pipeline Usage Example"
puts "=" * 50

# Configure JoobQ (pipeline optimization is always enabled)
JoobQ.configure do
  # Pipeline optimization settings
  pipeline_batch_size = 50
  pipeline_timeout = 1.0
  pipeline_max_commands = 1000

  # Set up error monitoring with alerts
  error_monitoring do |monitor|
    monitor.alert_thresholds = {
      "error" => 5,
      "warn"  => 20,
      "info"  => 100,
    }
    monitor.time_window = 5.minutes
    monitor.max_recent_errors = 200
  end

  # Define queues
  queue "email", 3, EmailJob
  queue "data_processing", 2, DataProcessingJob
end

puts "✅ Configuration completed (pipeline optimization is always enabled)"
puts ""

# Example 1: Batch Job Enqueuing
puts "📤 Example 1: Batch Job Enqueuing"
puts "-" * 30

# Create multiple email jobs
email_jobs = [] of EmailJob
10.times do |i|
  email_jobs << EmailJob.new(
    to: "user#{i}@example.com",
    subject: "Welcome Email #{i}",
    body: "Welcome to our service! This is email number #{i}."
  )
end

# Batch enqueue all email jobs (uses pipeline optimization)
puts "Enqueuing #{email_jobs.size} email jobs in batch..."
start_time = Time.monotonic
email_queue = JoobQ.queues["email"].as(JoobQ::Queue(EmailJob))
email_queue.add_batch(email_jobs)
enqueue_time = Time.monotonic - start_time
puts "✅ Batch enqueued in #{(enqueue_time.total_milliseconds).round(2)}ms"
puts ""

# Example 2: Batch Data Processing Jobs
puts "📊 Example 2: Batch Data Processing Jobs"
puts "-" * 30

# Create data processing jobs with different operations
data_jobs = [] of DataProcessingJob
data_sets = [
  [1, 2, 3, 4, 5],
  [10, 20, 30, 40, 50],
  [100, 200, 300],
  [5, 15, 25, 35, 45, 55],
]

data_sets.each_with_index do |data, i|
  data_jobs << DataProcessingJob.new(data: data, operation: i.even? ? "sum" : "average")
end

puts "Enqueuing #{data_jobs.size} data processing jobs in batch..."
start_time = Time.monotonic
data_queue = JoobQ.queues["data_processing"].as(JoobQ::Queue(DataProcessingJob))
data_queue.add_batch(data_jobs)
enqueue_time = Time.monotonic - start_time
puts "✅ Batch enqueued in #{(enqueue_time.total_milliseconds).round(2)}ms"
puts ""

# Example 3: Error Monitoring with Batch Operations
puts "🚨 Example 3: Error Monitoring with Batch Operations"
puts "-" * 30

# Simulate some errors
error_contexts = [] of JoobQ::ErrorContext
5.times do |i|
  error_context = JoobQ::ErrorContext.new(
    job_id: "email_job_#{i}",
    queue_name: "email",
    worker_id: "worker_1",
    job_type: "EmailJob",
    error_type: "smtp_error",
    error_message: "SMTP server temporarily unavailable",
    error_class: "SMTPError",
    backtrace: ["smtp_client.cr:45", "email_job.cr:23"],
    retry_count: 1,
    system_context: {"server" => "smtp.example.com", "attempt" => i.to_s}
  )
  error_contexts << error_context
end

# Batch store errors (uses pipeline optimization)
puts "Storing #{error_contexts.size} error contexts in batch..."
start_time = Time.monotonic
JoobQ.config.error_monitor.store_errors_batch(error_contexts)
error_time = Time.monotonic - start_time
puts "✅ Batch stored in #{(error_time.total_milliseconds).round(2)}ms"
puts ""

# Example 4: Queue Metrics Collection
puts "📈 Example 4: Queue Metrics Collection"
puts "-" * 30

# Get metrics for all queues (uses pipeline optimization)
puts "Collecting metrics for all queues..."
start_time = Time.monotonic
all_metrics = JoobQ.store.as(JoobQ::RedisStore).get_all_queue_metrics
metrics_time = Time.monotonic - start_time

puts "✅ Metrics collected in #{(metrics_time.total_milliseconds).round(2)}ms"
puts ""
puts "Queue Metrics:"
all_metrics.each do |queue_name, metrics|
  puts "  #{queue_name}:"
  puts "    Queue size: #{metrics.queue_size}"
  puts "    Processing: #{metrics.processing_size}"
  puts "    Failed: #{metrics.failed_count}"
  puts "    Dead letter: #{metrics.dead_letter_count}"
  puts "    Processed: #{metrics.processed_count}"
end
puts ""

# Example 5: Pipeline Statistics
puts "📊 Example 5: Pipeline Statistics"
puts "-" * 30

pipeline_stats = JoobQ::RedisStore.pipeline_stats
puts "Pipeline Performance:"
puts "  Total pipeline calls: #{pipeline_stats.total_pipeline_calls}"
puts "  Total commands batched: #{pipeline_stats.total_commands_batched}"
puts "  Average batch size: #{pipeline_stats.average_batch_size.round(2)}"
puts "  Pipeline failures: #{pipeline_stats.pipeline_failures}"
puts "  Success rate: #{((pipeline_stats.total_pipeline_calls - pipeline_stats.pipeline_failures).to_f / pipeline_stats.total_pipeline_calls * 100).round(1)}%"
puts ""

# Example 6: Start Workers and Process Jobs
puts "⚙️  Example 6: Starting Workers"
puts "-" * 30

# Start the queues to process jobs
JoobQ.queues["email"].start
JoobQ.queues["data_processing"].start

puts "✅ Workers started for email and data processing queues"
puts ""

# Wait a bit for jobs to be processed
puts "⏳ Waiting for jobs to be processed..."
sleep(3.seconds)

# Check final metrics
puts "📈 Final Queue Metrics:"
final_metrics = JoobQ.store.as(JoobQ::RedisStore).get_all_queue_metrics
final_metrics.each do |queue_name, metrics|
  puts "  #{queue_name}:"
  puts "    Queue size: #{metrics.queue_size}"
  puts "    Processing: #{metrics.processing_size}"
  puts "    Processed: #{metrics.processed_count}"
end
puts ""

# Example 7: Error Statistics
puts "🚨 Example 7: Error Statistics"
puts "-" * 30

error_stats = JoobQ.config.error_monitor.get_error_stats
puts "Error Statistics:"
error_stats.each do |error_key, count|
  puts "  #{error_key}: #{count}"
end
puts ""

# Example 8: Configuration Summary
puts "⚙️  Example 8: Pipeline Configuration Summary"
puts "-" * 30

puts "Current Pipeline Configuration:"
puts "  Pipeline optimization: Always enabled"
puts "  Pipeline batch size: #{JoobQ.config.pipeline_batch_size}"
puts "  Pipeline timeout: #{JoobQ.config.pipeline_timeout}s"
puts "  Pipeline max commands: #{JoobQ.config.pipeline_max_commands}"
puts ""

# Clean up
puts "🧹 Cleaning up..."
JoobQ.queues["email"].stop!
JoobQ.queues["data_processing"].stop!
JoobQ.config.error_monitor.clear_redis_errors

puts "✅ Cleanup completed"
puts ""

puts "🎯 Pipeline Usage Example Completed!"
puts ""
puts "Key Benefits Demonstrated:"
puts "  • Batch job enqueuing for better performance"
puts "  • Batch error monitoring with pipeline operations"
puts "  • Efficient queue metrics collection"
puts "  • Pipeline performance tracking and statistics"
puts "  • Configurable pipeline settings"
puts "  • Graceful error handling and fallbacks"
puts ""
puts "For production use:"
puts "  • Monitor pipeline statistics via /joobq/pipeline/stats"
puts "  • Check pipeline health via /joobq/pipeline/health"
puts "  • Tune batch sizes based on your workload"
puts "  • Pipeline optimization is always enabled for maximum performance"
