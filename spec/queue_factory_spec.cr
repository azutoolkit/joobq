require "./spec_helper"

describe JoobQ::QueueFactory do
  before_each do
    # Clear the registry before each test
    JoobQ::QueueFactory.clear_registry
  end

  after_each do
    # Re-register all test job types that were registered in spec_helper
    # This ensures other tests can still access the queues
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
  end

  describe ".register_job_type" do
    it "registers a job type in the factory" do
      JoobQ::QueueFactory.register_job_type(FactoryTestJob)

      JoobQ::QueueFactory.registered?("FactoryTestJob").should be_true
    end

    it "allows registering multiple job types" do
      JoobQ::QueueFactory.register_job_type(FactoryTestJob)
      JoobQ::QueueFactory.register_job_type(AnotherFactoryTestJob)

      JoobQ::QueueFactory.registered_types.should contain("FactoryTestJob")
      JoobQ::QueueFactory.registered_types.should contain("AnotherFactoryTestJob")
    end
  end

  describe ".create_queue" do
    it "creates a queue for a registered job type" do
      JoobQ::QueueFactory.register_job_type(FactoryTestJob)

      queue = JoobQ::QueueFactory.create_queue(
        name: "test_queue",
        job_class_name: "FactoryTestJob",
        workers: 5
      )

      queue.should_not be_nil
      queue.name.should eq("test_queue")
      queue.job_type.should eq("FactoryTestJob")
      queue.total_workers.should eq(5)
    end

    it "creates a queue with throttling" do
      JoobQ::QueueFactory.register_job_type(ThrottledFactoryTestJob)

      queue = JoobQ::QueueFactory.create_queue(
        name: "throttled_queue",
        job_class_name: "ThrottledFactoryTestJob",
        workers: 3,
        throttle: {limit: 10, period: 1.minute}
      )

      queue.should_not be_nil
      throttle = queue.throttle_limit
      throttle.should_not be_nil
      throttle.try do |t|
        t[:limit].should eq(10)
        t[:period].should eq(1.minute)
      end
    end

    it "raises error for unregistered job type" do
      expect_raises(JoobQ::QueueFactoryError, /not registered/) do
        JoobQ::QueueFactory.create_queue(
          name: "unknown_queue",
          job_class_name: "UnknownJob",
          workers: 1
        )
      end
    end

    it "includes available types in error message" do
      JoobQ::QueueFactory.register_job_type(FactoryTestJob)
      JoobQ::QueueFactory.register_job_type(AnotherFactoryTestJob)

      begin
        JoobQ::QueueFactory.create_queue(
          name: "test",
          job_class_name: "UnknownJob",
          workers: 1
        )
        fail "Should have raised QueueFactoryError"
      rescue ex : JoobQ::QueueFactoryError
        message = ex.message.not_nil!
        message.should contain("FactoryTestJob")
        message.should contain("AnotherFactoryTestJob")
      end
    end
  end

  describe ".create_queues_from_config" do
    it "creates multiple queues from configuration hash" do
      JoobQ::QueueFactory.register_job_type(FactoryTestJob)
      JoobQ::QueueFactory.register_job_type(AnotherFactoryTestJob)

      queue_configs = {
        "queue1" => {
          job_class_name: "FactoryTestJob",
          workers:        3,
          throttle:       nil,
        },
        "queue2" => {
          job_class_name: "AnotherFactoryTestJob",
          workers:        5,
          throttle:       {limit: 20, period: 1.minute},
        },
      }

      queues = JoobQ::QueueFactory.create_queues_from_config(queue_configs)

      queues.size.should eq(2)
      queues["queue1"].job_type.should eq("FactoryTestJob")
      queues["queue2"].job_type.should eq("AnotherFactoryTestJob")
    end

    it "skips unregistered job types and logs errors" do
      JoobQ::QueueFactory.register_job_type(FactoryTestJob)

      queue_configs = {
        "valid_queue" => {
          job_class_name: "FactoryTestJob",
          workers:        3,
          throttle:       nil,
        },
        "invalid_queue" => {
          job_class_name: "UnknownJob",
          workers:        1,
          throttle:       nil,
        },
      }

      queues = JoobQ::QueueFactory.create_queues_from_config(queue_configs)

      # Should create the valid queue but skip the invalid one
      queues.size.should eq(1)
      queues.has_key?("valid_queue").should be_true
      queues.has_key?("invalid_queue").should be_false
    end

    it "handles empty configuration" do
      queue_configs = {} of String => NamedTuple(
        job_class_name: String,
        workers: Int32,
        throttle: NamedTuple(limit: Int32, period: Time::Span)?)

      queues = JoobQ::QueueFactory.create_queues_from_config(queue_configs)

      queues.size.should eq(0)
    end
  end

  describe ".registered_types" do
    it "returns empty array when no types registered" do
      JoobQ::QueueFactory.registered_types.should be_empty
    end

    it "returns all registered type names" do
      JoobQ::QueueFactory.register_job_type(FactoryTestJob)
      JoobQ::QueueFactory.register_job_type(AnotherFactoryTestJob)

      types = JoobQ::QueueFactory.registered_types
      types.size.should eq(2)
      types.should contain("FactoryTestJob")
      types.should contain("AnotherFactoryTestJob")
    end
  end

  describe ".registered?" do
    it "returns false for unregistered types" do
      JoobQ::QueueFactory.registered?("UnknownJob").should be_false
    end

    it "returns true for registered types" do
      JoobQ::QueueFactory.register_job_type(FactoryTestJob)
      JoobQ::QueueFactory.registered?("FactoryTestJob").should be_true
    end
  end

  describe "integration with Configure" do
    it "works with Configure.create_queues_from_yaml_config" do
      # Register job types
      JoobQ::QueueFactory.register_job_type(FactoryTestJob)
      JoobQ::QueueFactory.register_job_type(AnotherFactoryTestJob)

      # Create configuration with queue configs
      config = JoobQ::Configure.new
      config.queue_configs["test_queue"] = {
        job_class_name: "FactoryTestJob",
        workers:        3,
        throttle:       nil,
      }
      config.queue_configs["another_queue"] = {
        job_class_name: "AnotherFactoryTestJob",
        workers:        2,
        throttle:       {limit: 5, period: 30.seconds},
      }

      # Create queues from config
      num_created = config.create_queues_from_yaml_config

      num_created.should eq(2)
      config.queues.size.should eq(2)
      config.queues["test_queue"].job_type.should eq("FactoryTestJob")
      config.queues["another_queue"].job_type.should eq("AnotherFactoryTestJob")
    end
  end

  describe "BaseQueue interface" do
    it "returns queues as BaseQueue interface" do
      JoobQ::QueueFactory.register_job_type(FactoryTestJob)

      queue = JoobQ::QueueFactory.create_queue(
        name: "test",
        job_class_name: "FactoryTestJob",
        workers: 1
      )

      # Queue should implement BaseQueue interface
      queue.is_a?(JoobQ::BaseQueue).should be_true

      # BaseQueue methods should be available (without calling Redis)
      queue.name.should eq("test")
      queue.job_type.should eq("FactoryTestJob")
      queue.total_workers.should eq(1)
      queue.running_workers.should eq(0)
    end
  end
end

describe "YAML Configuration Integration" do
  before_each do
    JoobQ::QueueFactory.clear_registry
  end

  after_each do
    # Re-register all test job types that were registered in spec_helper
    # This ensures other tests can still access the queues
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
  end

  it "loads queues from YAML configuration" do
    # Register job types
    JoobQ::QueueFactory.register_job_type(FactoryTestJob)
    JoobQ::QueueFactory.register_job_type(AnotherFactoryTestJob)

    # Create YAML configuration
    yaml = <<-YAML
      joobq:
        settings:
          default_queue: "default"
          retries: 3

        queues:
          factory_test_queue:
            job_class: "FactoryTestJob"
            workers: 4

          another_test_queue:
            job_class: "AnotherFactoryTestJob"
            workers: 2
            throttle:
              limit: 10
              period: "1 minute"
      YAML

    # Load configuration
    config = JoobQ::YamlConfigLoader.load_from_string(yaml)

    # Verify queue configs were loaded
    config.queue_configs.size.should eq(2)
    config.queue_configs["factory_test_queue"][:job_class_name].should eq("FactoryTestJob")
    config.queue_configs["another_test_queue"][:job_class_name].should eq("AnotherFactoryTestJob")

    # Create queues from config
    config.create_queues_from_yaml_config

    # Verify queues were created
    config.queues.size.should eq(2)
    config.queues["factory_test_queue"].job_type.should eq("FactoryTestJob")
    config.queues["factory_test_queue"].total_workers.should eq(4)
    config.queues["another_test_queue"].job_type.should eq("AnotherFactoryTestJob")
    config.queues["another_test_queue"].total_workers.should eq(2)
  end

  it "handles YAML with unregistered job types gracefully" do
    # Only register one job type
    JoobQ::QueueFactory.register_job_type(FactoryTestJob)

    yaml = <<-YAML
      joobq:
        queues:
          valid_queue:
            job_class: "FactoryTestJob"
            workers: 2

          invalid_queue:
            job_class: "UnregisteredJob"
            workers: 1
      YAML

    config = JoobQ::YamlConfigLoader.load_from_string(yaml)
    config.create_queues_from_yaml_config

    # Should create only the valid queue
    config.queues.size.should eq(1)
    config.queues.has_key?("valid_queue").should be_true
    config.queues.has_key?("invalid_queue").should be_false
  end
end
