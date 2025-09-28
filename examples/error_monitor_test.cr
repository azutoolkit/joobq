require "../src/joobq"

# Simple test script for error monitoring without Redis dependency
puts "=== JoobQ Error Monitoring Test ==="
puts

# Test ErrorContext creation
puts "1. Testing ErrorContext creation..."

error_context = JoobQ::ErrorContext.new(
  job_id: "test-job-123",
  queue_name: "test-queue",
  job_type: "TestJob",
  error_type: "validation_error",
  error_message: "Invalid input parameter",
  error_class: "ArgumentError",
  backtrace: ["test.cr:15:5 in 'perform'", "test.cr:20:1 in 'main'"],
  retry_count: 1,
  worker_id: "worker-1",
  system_context: {"memory_usage" => "1024MB", "queue_size" => "5"}
)

puts "  ✓ ErrorContext created successfully"
puts "  Job ID: #{error_context.job_id}"
puts "  Error Type: #{error_context.error_type}"
puts "  Should Retry: #{error_context.should_retry?}"
puts "  Severity: #{error_context.severity}"
puts

# Test ErrorMonitor functionality
puts "2. Testing ErrorMonitor functionality..."

monitor = JoobQ::ErrorMonitor.new

# Record some test errors
error_types = ["validation_error", "connection_error", "timeout_error", "unknown_error"]
error_types.each_with_index do |error_type, index|
  context = JoobQ::ErrorContext.new(
    job_id: "job-#{index + 1}",
    queue_name: "test-queue",
    job_type: "TestJob",
    error_type: error_type,
    error_message: "Test #{error_type}",
    error_class: "TestError",
    backtrace: ["test.cr:#{index + 1}:1"],
    retry_count: index
  )

  monitor.record_error(context)
  puts "  ✓ Recorded #{error_type} error"
end

puts
puts "3. Testing error statistics..."

stats = monitor.get_error_stats
puts "  Error counts:"
stats.each do |key, count|
  puts "    #{key}: #{count}"
end

puts
puts "4. Testing error filtering..."

validation_errors = monitor.get_errors_by_type("validation_error")
puts "  Validation errors: #{validation_errors.size}"

connection_errors = monitor.get_errors_by_type("connection_error")
puts "  Connection errors: #{connection_errors.size}"

queue_errors = monitor.get_errors_by_queue("test-queue")
puts "  Test queue errors: #{queue_errors.size}"

puts
puts "5. Testing recent errors..."

recent_errors = monitor.get_recent_errors(3)
puts "  Recent errors (last 3):"
recent_errors.each_with_index do |error, index|
  puts "    #{index + 1}. #{error.error_type}: #{error.error_message}"
end

puts
puts "6. Testing error classification..."

# Test error classification
test_exceptions = [
  ArgumentError.new("Invalid argument"),
  Socket::ConnectError.new("Connection failed"),
  IO::TimeoutError.new("Timeout"),
  JSON::Error.new("JSON parse error"),
  KeyError.new("Missing key"),
  NotImplementedError.new("Not implemented"),
  RuntimeError.new("Generic error")
]

puts "  Error classification test:"
test_exceptions.each do |exception|
  classified_type = JoobQ::ErrorContext.classify_error(exception)
  puts "    #{exception.class.name} -> #{classified_type}"
end

puts
puts "7. Testing alert thresholds..."

# Set low threshold for testing
monitor.alert_thresholds["error"] = 2

# Add more errors to trigger alert
(5..7).each do |i|
  context = JoobQ::ErrorContext.new(
    job_id: "alert-job-#{i}",
    queue_name: "test-queue",
    job_type: "TestJob",
    error_type: "test_error",
    error_message: "Alert test error #{i}",
    error_class: "TestError",
    backtrace: ["test.cr:#{i}:1"],
    retry_count: 0
  )

  monitor.record_error(context)
end

puts "  ✓ Added errors to trigger alert threshold"

puts
puts "8. Testing error context methods..."

# Test to_log_context
log_context = error_context.to_log_context
puts "  Log context keys: #{log_context.keys.join(", ")}"

# Test retry delay
retry_delay = error_context.retry_delay
puts "  Retry delay: #{retry_delay}"

puts
puts "9. Testing error monitor reset..."

puts "  Errors before reset: #{monitor.get_recent_errors.size}"
monitor.reset
puts "  Errors after reset: #{monitor.get_recent_errors.size}"

puts
puts "=== Error Monitoring Test Completed Successfully! ==="
puts
puts "Key features tested:"
puts "  ✓ ErrorContext creation and properties"
puts "  ✓ ErrorMonitor error recording"
puts "  ✓ Error statistics and counting"
puts "  ✓ Error filtering by type and queue"
puts "  ✓ Recent errors retrieval"
puts "  ✓ Error classification"
puts "  ✓ Alert threshold testing"
puts "  ✓ Error context utility methods"
puts "  ✓ Monitor reset functionality"
