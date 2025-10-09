require "../src/joobq"

# Example: Custom Alert Notifications
# This example demonstrates how to configure custom alert notifications
# to send alerts to external services like Slack, email, or logging systems

# Simulate a Slack notification service
class SlackNotifier
  def self.send(alert_context : Hash(String, String))
    puts "\n📢 SLACK NOTIFICATION:"
    puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    puts "🚨 JoobQ Alert: #{alert_context["error_type"]}"
    puts "Queue: #{alert_context["queue_name"]}"
    puts "Count: #{alert_context["current_count"]} / #{alert_context["threshold"]}"
    puts "Severity: #{alert_context["severity"]}"
    puts "Time Window: #{alert_context["time_window"]}"
    puts "Occurred At: #{alert_context["occurred_at"]}"
    puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
  end
end

# Simulate an email service
class EmailNotifier
  def self.send(alert_context : Hash(String, String))
    puts "\n📧 EMAIL NOTIFICATION:"
    puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    puts "To: devops@company.com"
    puts "Subject: [#{alert_context["severity"].upcase}] JoobQ Alert"
    puts "Body:"
    alert_context.each do |key, value|
      puts "  #{key}: #{value}"
    end
    puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
  end
end

# Define a test job first (before configure block)
struct TestJob
  include JoobQ::Job

  property id : Int32
  @queue = "test"

  def initialize(@id : Int32)
  end

  def perform
    puts "Processing job #{@id}..."
    raise "Simulated error for testing"
  end
end

# Configure JoobQ with custom alert notifications
JoobQ.configure do |config|
  config.store = JoobQ::RedisStore.new
  config.default_queue = "test"

  # Configure error monitoring with custom notification handler
  config.error_monitoring do |monitor|
    monitor.alert_thresholds = {
      "error" => 3, # Alert after 3 errors (low for demo purposes)
      "warn"  => 5,
      "info"  => 10,
    }
    monitor.time_window = 5.minutes
    monitor.max_recent_errors = 100

    # Set custom alert notification handler
    # This proc will be called whenever an alert threshold is exceeded
    monitor.notify_alert = ->(alert_context : Hash(String, String)) {
      severity = alert_context["severity"]

      # Send to Slack for all severities
      SlackNotifier.send(alert_context)

      # Send email only for errors and warnings
      if severity == "error" || severity == "warn"
        EmailNotifier.send(alert_context)
      end
    }
  end

  # Define a test queue
  queue "test", 2, TestJob
end

# Example: Using parameters to configure notification handler
puts "\n=== Example 1: Configuration with Block ==="

# Alternative approach using parameters
puts "\n=== Example 2: Configuration with Parameters ==="

# Define notification handler
notification_handler = ->(alert_context : Hash(String, String)) {
  puts "\n🔔 CUSTOM HANDLER:"
  puts "Alert Type: #{alert_context["alert_type"]}"
  puts "Error: #{alert_context["error_type"]} in #{alert_context["queue_name"]}"
  puts "Count: #{alert_context["current_count"]} (threshold: #{alert_context["threshold"]})"
}

# Configure with parameters
JoobQ.configure do |config|
  config.error_monitoring(
    alert_thresholds: {"error" => 3, "warn" => 5},
    time_window: 5.minutes,
    notify_alert: notification_handler
  )
end

puts "\n✅ Custom alert notifications configured successfully!"
puts "\nAvailable alert context fields:"
puts "  - alert_type: Type of alert (e.g., 'error_threshold_exceeded')"
puts "  - error_type: The error type (e.g., 'connection_error')"
puts "  - queue_name: Name of the affected queue"
puts "  - current_count: Current error count in time window"
puts "  - threshold: Configured threshold"
puts "  - severity: Severity level ('error', 'warn', 'info')"
puts "  - time_window: Time window for counting"
puts "  - occurred_at: Timestamp (RFC3339 format)"
puts "\nYou can integrate with any external service:"
puts "  - Slack (webhooks)"
puts "  - PagerDuty (API)"
puts "  - Email (SMTP)"
puts "  - Sentry, DataDog, New Relic, etc."
puts "  - Custom logging systems"
puts "  - SMS/Phone notifications"

# Cleanup
JoobQ.error_monitor.reset
