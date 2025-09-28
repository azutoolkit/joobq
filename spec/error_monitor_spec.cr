require "spec"
require "../src/joobq"

# Define test job classes
class ErrorMonitorTestJob
  include JoobQ::Job

  getter x : Int32
  @queue = "example"
  @retries = 3

  def initialize(@x : Int32)
  end

  def perform
    @x + 1
  end
end

# Use existing configuration from spec_helper

module JoobQ
  describe ErrorMonitor do
    before_each do
      JoobQ.reset
      JoobQ.error_monitor.reset
    end

    describe "#record_error" do
      it "records error context and updates counts" do
        error_context = ErrorContext.new(
          job_id: "test-job-1",
          queue_name: "example",
          worker_id: "test-worker",
          job_type: "TestJob",
          error_type: "test_error",
          error_message: "Test error message",
          error_class: "RuntimeError",
          backtrace: ["line 1", "line 2"],
          retry_count: 0
        )

        JoobQ.error_monitor.record_error(error_context)

        stats = JoobQ.error_monitor.get_error_stats
        stats["test_error:example"].should eq 1

        recent_errors = JoobQ.error_monitor.get_recent_errors
        recent_errors.size.should eq 1
        recent_errors.first.job_id.should eq "test-job-1"
      end

      it "triggers alerts when threshold is exceeded" do
        # Set a low threshold for testing
        JoobQ.error_monitor.alert_thresholds["error"] = 2

        error_context = ErrorContext.new(
          job_id: "test-job-1",
          queue_name: "example",
          worker_id: "test-worker",
          job_type: "TestJob",
          error_type: "test_error",
          error_message: "Test error message",
          error_class: "RuntimeError",
          backtrace: ["line 1"],
          retry_count: 0
        )

        # Record errors up to threshold
        JoobQ.error_monitor.record_error(error_context)
        JoobQ.error_monitor.record_error(error_context)

        stats = JoobQ.error_monitor.get_error_stats
        stats["test_error:example"].should eq 2
      end
    end

    describe "#get_errors_by_type" do
      it "filters errors by type" do
        error1 = ErrorContext.new(
          job_id: "job-1",
          queue_name: "queue-1",
          worker_id: "test-worker",
          job_type: "TestJob",
          error_type: "validation_error",
          error_message: "Validation failed",
          error_class: "ArgumentError",
          backtrace: ["line 1"],
          retry_count: 0
        )

        error2 = ErrorContext.new(
          job_id: "job-2",
          queue_name: "queue-1",
          worker_id: "test-worker",
          job_type: "TestJob",
          error_type: "connection_error",
          error_message: "Connection failed",
          error_class: "Socket::ConnectError",
          backtrace: ["line 1"],
          retry_count: 0
        )

        JoobQ.error_monitor.record_error(error1)
        JoobQ.error_monitor.record_error(error2)

        validation_errors = JoobQ.error_monitor.get_errors_by_type("validation_error")
        validation_errors.size.should eq 1
        validation_errors.first.job_id.should eq "job-1"

        connection_errors = JoobQ.error_monitor.get_errors_by_type("connection_error")
        connection_errors.size.should eq 1
        connection_errors.first.job_id.should eq "job-2"
      end
    end

    describe "#get_errors_by_queue" do
      it "filters errors by queue name" do
        error1 = ErrorContext.new(
          job_id: "job-1",
          queue_name: "queue-1",
          worker_id: "test-worker",
          job_type: "TestJob",
          error_type: "test_error",
          error_message: "Test error",
          error_class: "RuntimeError",
          backtrace: ["line 1"],
          retry_count: 0
        )

        error2 = ErrorContext.new(
          job_id: "job-2",
          queue_name: "queue-2",
          worker_id: "test-worker",
          job_type: "TestJob",
          error_type: "test_error",
          error_message: "Test error",
          error_class: "RuntimeError",
          backtrace: ["line 1"],
          retry_count: 0
        )

        JoobQ.error_monitor.record_error(error1)
        JoobQ.error_monitor.record_error(error2)

        queue1_errors = JoobQ.error_monitor.get_errors_by_queue("queue-1")
        queue1_errors.size.should eq 1
        queue1_errors.first.job_id.should eq "job-1"

        queue2_errors = JoobQ.error_monitor.get_errors_by_queue("queue-2")
        queue2_errors.size.should eq 1
        queue2_errors.first.job_id.should eq "job-2"
      end
    end

    describe "#clear_old_errors" do
      it "removes errors older than time window" do
        # Set a longer time window initially so the error doesn't get immediately removed
        monitor = ErrorMonitor.new(time_window: 5.seconds)

        error_context = ErrorContext.new(
          job_id: "old-job",
          queue_name: "example",
          worker_id: "test-worker",
          job_type: "TestJob",
          error_type: "test_error",
          error_message: "Old error",
          error_class: "RuntimeError",
          backtrace: ["line 1"],
          retry_count: 0,
          occurred_at: (Time.local - 2.seconds).to_rfc3339
        )

        monitor.record_error(error_context)
        monitor.recent_errors.size.should eq 1

        # Now change the time window to be shorter than the error age
        monitor = ErrorMonitor.new(time_window: 1.second)

        # Re-record the same error with the new time window
        monitor.record_error(error_context)
        monitor.recent_errors.size.should eq 0
      end
    end

    describe "#reset" do
      it "clears all error data" do
        error_context = ErrorContext.new(
          job_id: "test-job",
          queue_name: "example",
          worker_id: "test-worker",
          job_type: "TestJob",
          error_type: "test_error",
          error_message: "Test error",
          error_class: "RuntimeError",
          backtrace: ["line 1"],
          retry_count: 0
        )

        JoobQ.error_monitor.record_error(error_context)
        JoobQ.error_monitor.get_error_stats.size.should eq 1
        JoobQ.error_monitor.get_recent_errors.size.should eq 1

        JoobQ.error_monitor.reset

        JoobQ.error_monitor.get_error_stats.size.should eq 0
        JoobQ.error_monitor.get_recent_errors.size.should eq 0
      end
    end
  end

  describe MonitoredErrorHandler do
    before_each do
      JoobQ.reset
      JoobQ.error_monitor.reset
    end

    it "handles job errors and records them in monitor" do
      job = ErrorMonitorTestJob.new(1)
      queue = Queue(ErrorMonitorTestJob).new("example", 1)

      # Create an exception
      exception = RuntimeError.new("Test error")

      # Handle the error
      error_context = MonitoredErrorHandler.handle_job_error(
        job,
        queue,
        exception,
        worker_id: "test-worker",
        additional_context: {"test_key" => "test_value"}
      )

      # Verify error context was created
      error_context.job_id.should eq job.jid.to_s
      error_context.queue_name.should eq "example"
      error_context.error_message.should eq "Test error"
      error_context.worker_id.should eq "test-worker"
      error_context.system_context["test_key"].should eq "test_value"

      # Verify error was recorded in monitor
      stats = JoobQ.error_monitor.get_error_stats
      stats["unknown_error:example"].should eq 1

      recent_errors = JoobQ.error_monitor.get_recent_errors
      recent_errors.size.should eq 1
      recent_errors.first.job_id.should eq job.jid.to_s
    end

    it "classifies different error types correctly" do
      job = ErrorMonitorTestJob.new(1)
      queue = Queue(ErrorMonitorTestJob).new("example", 1)

      # Test different exception types
      test_cases = [
        {exception: ArgumentError.new("Invalid argument"), expected_type: "validation_error"},
        {exception: Socket::ConnectError.new("Connection failed"), expected_type: "connection_error"},
        {exception: IO::TimeoutError.new("Timeout"), expected_type: "timeout_error"},
        {exception: JSON::Error.new("JSON parse error"), expected_type: "serialization_error"},
        {exception: KeyError.new("Missing key"), expected_type: "configuration_error"},
        {exception: NotImplementedError.new("Not implemented"), expected_type: "implementation_error"},
        {exception: RuntimeError.new("Generic error"), expected_type: "unknown_error"}
      ]

      test_cases.each do |test_case|
        JoobQ.error_monitor.reset

        error_context = MonitoredErrorHandler.handle_job_error(
          job,
          queue,
          test_case[:exception],
          worker_id: "test-worker"
        )

        error_context.error_type.should eq test_case[:expected_type]
      end
    end
  end
end
