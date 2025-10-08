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
  # # 2b. Or get all instantiated queues from configuration (memoized)
  # all_queues = QueueFactory.queues  # Reads from JoobQ.config and caches
  # ```
  #
  # ## Memoization Pattern:
  #
  # The `queues` method integrates with `Configure` and `YamlConfigLoader` to:
  # - Read queue configurations from `JoobQ.config.queue_configs`
  # - Instantiate all configured queues on first access
  # - Cache the queue instances for subsequent calls
  # - Support cache clearing via `clear_queues_cache` or `clear_registry`
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
  # 5. Queues are instantiated lazily and memoized from configuration
  class QueueFactory
    # Type alias for the factory function
    alias FactoryProc = Proc(String, Int32, NamedTuple(limit: Int32, period: Time::Span)?, BaseQueue)
    alias RegistryProc = Proc(JobSchemaRegistry, Nil)

    # Registry of job class names to queue factory functions
    @@registry = {} of String => FactoryProc

    # Registry of job class names to schema registry functions
    # Used to populate JobSchemaRegistry after config reset
    @@schema_registry_procs = {} of String => RegistryProc

    # Memoized queues cache
    @@queues_cache : Hash(String, BaseQueue)? = nil

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

    # Get all instantiated queues from configuration
    #
    # This method instantiates and memoizes all queues based on the queue_configs
    # defined in the Configure instance. Queues are created lazily on first access
    # and cached for subsequent calls.
    #
    # The method:
    # 1. Checks if queues are already cached
    # 2. If not, retrieves queue_configs from JoobQ.config
    # 3. Creates queue instances using the factory registry
    # 4. Caches and returns the queue hash indexed by queue name
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
      return @@queues_cache.not_nil! if @@queues_cache

      # Get queue configurations from Configure instance
      config = JoobQ.config
      queue_configs = config.queue_configs

      # Create queues from configuration
      created_queues = create_queues_from_config(queue_configs)

      # Cache the queues hash
      @@queues_cache = created_queues

      Log.info { "Memoized #{@@queues_cache.not_nil!.size} queues from configuration" }

      @@queues_cache.not_nil!
    end

    # Internal method to add a factory function to the registry
    def self.add_to_registry(job_class_name : String, factory : FactoryProc, schema_proc : RegistryProc)
      @@registry[job_class_name] = factory
      @@schema_registry_procs[job_class_name] = schema_proc
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

    # Clear the registry and queues cache (mainly for testing or config reload)
    def self.clear_registry
      @@registry.clear
      @@schema_registry_procs.clear
      @@queues_cache = nil
    end

    # Clear only the queues cache (forces re-instantiation on next access)
    def self.clear_queues_cache
      @@queues_cache = nil
      Log.debug { "Cleared queues cache - queues will be re-instantiated on next access" }
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
