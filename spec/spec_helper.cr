require "spec"
# Set environment for test configuration BEFORE loading joobq
ENV["JOOBQ_ENV"] = "test"

require "../src/joobq"
require "./helpers/all_test_jobs"

# Reset configuration and load from YAML file
JoobQ.reset_config
config_path = File.expand_path("../config/joobq.test.yml", __DIR__)
JoobQ.initialize_config_with(:file, config_path)

# Explicitly register all test job types with QueueFactory
# The finalized macro should handle this automatically, but for testing
# we ensure it's done explicitly
JoobQ::QueueFactory.register_job_type(Job1)
JoobQ::QueueFactory.register_job_type(ExampleJob)
JoobQ::QueueFactory.register_job_type(FailJob)
JoobQ::QueueFactory.register_job_type(TestJob)
JoobQ::QueueFactory.register_job_type(RetryTestJob)
JoobQ::QueueFactory.register_job_type(FailingRetryJob)
JoobQ::QueueFactory.register_job_type(NoRetryFailJob)
JoobQ::QueueFactory.register_job_type(ErrorMonitorTestJob)
JoobQ::QueueFactory.register_job_type(FactoryTestJob)
JoobQ::QueueFactory.register_job_type(AnotherFactoryTestJob)
JoobQ::QueueFactory.register_job_type(ThrottledFactoryTestJob)

# Populate job_registry from QueueFactory's registered types
JoobQ::QueueFactory.populate_schema_registry(JoobQ.config.job_registry)

# Create queues from YAML configuration
JoobQ.config.create_queues_from_yaml_config

# Configure schedulers programmatically (YAML scheduler config requires job class resolution)
JoobQ.configure do
  scheduler do
    # Silent cron job for testing (no output)
    cron(pattern: "*/30 * * * *") { }
    cron(pattern: "*/5 20-23 * * *") { }
    every(1.minute, ExampleJob, x: 1)
  end
end

# Workers started by any spec (including standalone queues the registries do
# not know about) are stopped when the example ends, so none can keep claiming
# jobs that a later example enqueues.
module SpecWorkers
  STOPPERS = [] of ->

  def self.stop_all
    STOPPERS.each(&.call)
    STOPPERS.clear
  end
end

class JoobQ::Worker(T)
  def run
    SpecWorkers::STOPPERS << -> { terminate if running.get }
    previous_def
  end
end

Spec.before_each do
  # Two queue registries exist (QueueFactory vs. config.queues); stop! blocks
  # until the queue's workers have exited.
  [JoobQ.config.queues, JoobQ.queues].each do |registry|
    registry.each_value { |queue| queue.stop! if queue.running? }
  end

  JoobQ.reset
end

Spec.after_each { SpecWorkers.stop_all }
