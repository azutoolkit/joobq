require "../src/joobq"

# Example job that will fail
class FailingJob
  include JoobQ::Job

  getter x : Int32
  @queue = "error-test"
  @retries = 2

  def initialize(@x : Int32)
  end

  def perform
    puts "Processing job with x = #{@x}"

    # Simulate different types of failures
    case @x
    when 1
      raise ArgumentError.new("Invalid argument: #{@x}")
    when 2
      raise Socket::ConnectError.new("Connection failed")
    when 3
      raise IO::TimeoutError.new("Operation timed out")
    when 4
      raise JSON::Error.new("JSON parsing failed")
    when 5
      raise KeyError.new("Missing required key")
    when 6
      raise NotImplementedError.new("Feature not implemented")
    else
      raise RuntimeError.new("Unexpected error with x = #{@x}")
    end
  end
end

# Example job that succeeds
class SuccessfulJob
  include JoobQ::Job

  getter x : Int32
  @queue = "error-test"
  @retries = 1

  def initialize(@x : Int32)
  end

  def perform
    puts "Successfully processed job with x = #{@x}"
    @x * 2
  end
end

# Configure JoobQ
JoobQ.configure do
  queue "error-test", 5, FailingJob | SuccessfulJob
end

puts "=== JoobQ Error Monitoring Example ==="
puts

# Start the queue
queue = JoobQ["error-test"]
queue.start

# Add some failing jobs
puts "Adding failing jobs..."
(1..7).each do |i|
  job = FailingJob.new(i)
  JoobQ.add(job)
  puts "  Added FailingJob with x = #{i}"
end

# Add some successful jobs
puts "Adding successful jobs..."
(1..3).each do |i|
  job = SuccessfulJob.new(i)
  JoobQ.add(job)
  puts "  Added SuccessfulJob with x = #{i}"
end

puts
puts "Processing jobs for 5 seconds..."
sleep 5.seconds

puts
puts "=== Error Monitoring Results ==="

# Get error statistics
error_stats = JoobQ.error_monitor.get_error_stats
puts "Error counts by type and queue:"
error_stats.each do |key, count|
  puts "  #{key}: #{count}"
end

puts
puts "Recent errors (last 10):"
recent_errors = JoobQ.error_monitor.get_recent_errors(10)
recent_errors.each_with_index do |error, index|
  puts "  #{index + 1}. #{error.error_type} in #{error.queue_name} (#{error.error_class}): #{error.error_message}"
end

puts
puts "Errors by type:"
error_types = ["validation_error", "connection_error", "timeout_error", "serialization_error", "configuration_error", "implementation_error", "unknown_error"]
error_types.each do |type|
  errors = JoobQ.error_monitor.get_errors_by_type(type)
  if errors.any?
    puts "  #{type}: #{errors.size} errors"
    errors.each do |error|
      puts "    - Job #{error.job_id}: #{error.error_message}"
    end
  end
end

puts
puts "Errors by queue:"
queue_errors = JoobQ.error_monitor.get_errors_by_queue("error-test")
puts "  error-test queue: #{queue_errors.size} errors"

puts
puts "=== Testing Error Monitoring Features ==="

# Test alert thresholds
puts "Setting low alert threshold for testing..."
JoobQ.error_monitor.alert_thresholds["error"] = 3

# Add more errors to trigger alerts
puts "Adding more errors to trigger alerts..."
(8..10).each do |i|
  job = FailingJob.new(i)
  JoobQ.add(job)
end

sleep 2.seconds

# Test error filtering
puts
puts "Testing error filtering:"
puts "  Total recent errors: #{JoobQ.error_monitor.get_recent_errors.size}"
puts "  Validation errors: #{JoobQ.error_monitor.get_errors_by_type('validation_error').size}"
puts "  Connection errors: #{JoobQ.error_monitor.get_errors_by_type('connection_error').size}"
puts "  Unknown errors: #{JoobQ.error_monitor.get_errors_by_type('unknown_error').size}"

# Test error context details
puts
puts "Error context details for first error:"
if recent_errors.any?
  error = recent_errors.first
  puts "  Job ID: #{error.job_id}"
  puts "  Queue: #{error.queue_name}"
  puts "  Job Type: #{error.job_type}"
  puts "  Error Type: #{error.error_type}"
  puts "  Error Class: #{error.error_class}"
  puts "  Error Message: #{error.error_message}"
  puts "  Retry Count: #{error.retry_count}"
  puts "  Worker ID: #{error.worker_id}"
  puts "  Occurred At: #{error.occurred_at}"
  puts "  System Context: #{error.system_context}"
  puts "  Should Retry: #{error.should_retry?}"
  puts "  Severity: #{error.severity}"
end

# Clean up
puts
puts "Cleaning up..."
queue.stop!
JoobQ.error_monitor.reset

puts "Example completed!"
