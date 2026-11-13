module JoobQ
  # Queue Factory for creating queues from string-based job class names
  #
  # This factory solves the problem of instantiating generic Queue(T) classes
  # when the job type T is only known as a string at runtime (from YAML config).
  #
  # ## Basic Usage:
  #
  # ```
  # # 1. Register job types at compile-time (in your application code)
  # QueueFactory.register_job_type(EmailJob)
  # QueueFactory.register_job_type(ImageProcessingJob)
  #
  # # 2a. Create queues individually using string names (from YAML)
  # queue = QueueFactory.create_queue(
  #   name: "email_queue",
  #   job_class_name: "EmailJob",
  #   workers: 5,
  #   throttle: {limit: 10, period: 1.minute}
  # )
  #
  # # 2b. Or get the process's queue registry, `JoobQ.config.queues`
  # all_queues = QueueFactory.queues
  # ```
  #
  # ## The Registry:
  #
  # `JoobQ.config.queues` is the one registry of queues. `queues` creates the
  # entries of `JoobQ.config.queue_configs` missing from it, once, stores them
  # there and returns that Hash. Reset it with `JoobQ.reset_config`.
  #
  # ## The Crystal Limitation
  #
  # Crystal is statically-typed and compiled. Generic types like Queue(T) must
  # be instantiated at compile-time, not runtime. You cannot do:
  #
  # ```
  # # ❌ This doesn't work in Crystal
  # job_class_name = "EmailJob"  # from YAML
  # queue = Queue(job_class_name.constantize).new  # .constantize doesn't exist!
  # ```
  #
  # ## The Solution
  #
  # Use a factory pattern where:
  # 1. All possible job types are registered at compile-time
  # 2. The factory uses a hash mapping string names to factory procs
  # 3. Each factory proc creates the correctly-typed queue
  # 4. We return BaseQueue interface to hide the generic type
  # 5. Queues are instantiated lazily into `JoobQ.config.queues`
  class QueueFactory
    # Type alias for the factory function
    alias FactoryProc = Proc(String, Int32, NamedTuple(limit: Int32, period: Time::Span)?, BaseQueue)
    alias RegistryProc = Proc(JobSchemaRegistry, Nil)

    # Registry of job class names to queue factory functions
    @@registry = {} of String => FactoryProc

    # Registry of job class names to schema registry functions
    # Used to populate JobSchemaRegistry after config reset
    @@schema_registry_procs = {} of String => RegistryProc

    # YAML queue names `queues` failed to create for the configuration `@@failed_for`; tried again only after a
    # job type is registered, so a stale entry is not retried and logged on every call.
    @@failed = Set(String).new
    @@failed_for : Configure? = nil

    # Register a job type for queue creation
    #
    # This macro creates a factory function for the given job type and
    # stores it in the registry using the job class name as the key.
    #
    # Example:
    # ```
    # QueueFactory.register_job_type(EmailJob)
    # QueueFactory.register_job_type(ImageProcessingJob)
    # ```
    macro register_job_type(job_class)
      {% job_name = job_class.stringify %}
      ::JoobQ::QueueFactory.add_to_registry(
        {{job_name}},
        ->(name : String, workers : Int32, throttle : NamedTuple(limit: Int32, period: Time::Span)?) {
          ::JoobQ::Queue({{job_class.id}}).new(name, workers, throttle).as(::JoobQ::BaseQueue)
        },
        ->(registry : ::JoobQ::JobSchemaRegistry) {
          registry.register({{job_class.id}})
        }
      )
    end

    # The queue registry, `JoobQ.config.queues`, with the YAML-configured queues
    # it lacks created into it. A typed (DSL) queue wins over a YAML entry of the
    # same name, and a queue is created only once (an entry that fails is tried again
    # only after a job type is registered).
    #
    # Returns: Hash(String, BaseQueue) - queues indexed by queue name
    #
    # Example:
    # ```
    # # After registering job types and loading YAML config
    # QueueFactory.register_job_type(EmailJob)
    # QueueFactory.register_job_type(ImageProcessingJob)
    # config = Configure.load_from_yaml("config/joobq.yml")
    #
    # # Get all instantiated queues
    # all_queues = QueueFactory.queues
    # email_queue = all_queues["email_queue"]?
    # ```
    def self.queues : Hash(String, BaseQueue)
      config = JoobQ.config
      unless @@failed_for.same?(config)
        @@failed.clear
        @@failed_for = config
      end
      registry = config.queues
      return registry unless config.queue_configs.any? { |name, _| pending?(registry, name) }

      missing = config.queue_configs.select { |name, _| pending?(registry, name) }
      registry.merge!(create_queues_from_config(missing))
      missing.each_key { |name| @@failed << name unless registry.has_key?(name) }
      registry
    end

    private def self.pending?(registry : Hash(String, BaseQueue), name : String) : Bool
      !registry.has_key?(name) && !@@failed.includes?(name)
    end

    # Internal method to add a factory function to the registry
    def self.add_to_registry(job_class_name : String, factory : FactoryProc, schema_proc : RegistryProc)
      @@registry[job_class_name] = factory
      @@schema_registry_procs[job_class_name] = schema_proc
      @@failed.clear
    end

    # Create a queue based on string job class name
    #
    # Parameters:
    # - `name`: Queue name
    # - `job_class_name`: String name of the job class (e.g., "EmailJob")
    # - `workers`: Number of workers for this queue
    # - `throttle`: Optional throttling configuration
    #
    # Returns: A BaseQueue instance
    #
    # Raises: QueueFactoryError if the job class is not registered
    def self.create_queue(
      name : String,
      job_class_name : String,
      workers : Int32,
      throttle : NamedTuple(limit: Int32, period: Time::Span)? = nil,
    ) : BaseQueue
      factory = @@registry[job_class_name]?

      unless factory
        available_types = @@registry.keys.join(", ")
        raise QueueFactoryError.new(
          "Job class '#{job_class_name}' is not registered. " \
          "Available types: #{available_types}. " \
          "Register it using: QueueFactory.register_job_type(#{job_class_name})"
        )
      end

      factory.call(name, workers, throttle)
    end

    # Create queues from YAML configuration data
    #
    # This method takes the queue_configs hash from Configure and
    # creates actual Queue instances for all configured queues.
    #
    # Example:
    # ```
    # config = YamlConfigLoader.load_from_file("config/joobq.yml")
    # queues = QueueFactory.create_queues_from_config(config.queue_configs)
    # queues.each do |name, queue|
    #   config.queues[name] = queue
    # end
    # ```
    def self.create_queues_from_config(
      queue_configs : Hash(String, NamedTuple(job_class_name: String, workers: Int32, throttle: NamedTuple(limit: Int32, period: Time::Span)?)),
    ) : Hash(String, BaseQueue)
      queues = {} of String => BaseQueue

      queue_configs.each do |queue_name, queue_config|
        begin
          queue = create_queue(
            name: queue_name,
            job_class_name: queue_config[:job_class_name],
            workers: queue_config[:workers],
            throttle: queue_config[:throttle]
          )
          queues[queue_name] = queue
          Log.info { "Created queue '#{queue_name}' for job type '#{queue_config[:job_class_name]}' with #{queue_config[:workers]} workers" }
        rescue ex : QueueFactoryError
          Log.error { "Failed to create queue '#{queue_name}': #{ex.message}" }
        end
      end

      queues
    end

    # Get list of registered job types
    def self.registered_types : Array(String)
      @@registry.keys
    end

    # Check if a job type is registered
    def self.registered?(job_class_name : String) : Bool
      @@registry.has_key?(job_class_name)
    end

    # Clear the job type registry (mainly for testing)
    def self.clear_registry
      @@registry.clear
      @@schema_registry_procs.clear
      @@failed.clear
    end

    # Does nothing: there is no cache to clear.
    @[Deprecated("Does nothing: queues live in `JoobQ.config.queues`. To rebuild one after editing `queue_configs`, delete it from `JoobQ.queues` and call `JoobQ.queues` again, or `JoobQ.reset_config`")]
    def self.clear_queues_cache : Nil
    end

    # Populate a JobSchemaRegistry with all registered job types
    # This is useful after config reset to repopulate the job_registry
    def self.populate_schema_registry(registry : JobSchemaRegistry)
      @@schema_registry_procs.each_value do |proc|
        proc.call(registry)
      end
    end
  end

  # Exception raised when a job class is not registered in the factory
  class QueueFactoryError < Exception
  end
end
