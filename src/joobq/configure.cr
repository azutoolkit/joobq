module JoobQ
  # ### Struct `JoobQ::Configure`
  #
  # This struct is responsible for configuring and managing settings for the `JoobQ` job queue system.
  #
  # #### Properties and Getters
  #
  # - `INSTANCE`: A constant that holds a singleton instance of the `Configure` struct.
  # - `redis`: A getter that returns a `Redis::PooledClient` instance. The Redis client is configured using environment
  #   variables, including host, port, password, pool size, and timeout settings.
  # - `queues`: A getter returning a hash mapping queue names to their corresponding `BaseQueue` instances.
  # - `stats_enabled`: A property indicating whether statistics tracking is enabled. Defaults to `false`.
  # - `default_queue`: A property defining the name of the default queue. Defaults to `"default"`.
  # - `retries`: A property indicating the number of retries for a job. Defaults to `3`.
  # - `expires`: A property setting the expiration time for a job in seconds. Defaults to `3.days.total_seconds.to_i`.
  # - `timeout`: A property indicating the timeout setting. Defaults to `2`.
  #
  # #### Macro `queue`
  #
  # - `queue(name, workers, kind)`: A macro for defining queues. It takes a queue name, the number of workers,
  # and the kind of jobs the queue will handle. This macro creates and stores a new `JoobQ::Queue` instance in the
  # `queues` hash.
  #
  # #### Method `scheduler`
  #
  # - `scheduler`: A method that yields the singleton instance of the `Scheduler`. This is useful for accessing the scheduler within the scope of the `Configure` struct.
  #
  # ### Usage Example
  #
  # To utilize the `Configure` struct for setting up queues, you can define them using the `queue` macro:
  #
  # ```
  # JoobQ::Configure.instance.queue "my_queue", 5, MyJob
  # ```
  #
  # This would create a new queue named "my_queue" with 5 workers that handle `MyJob` type jobs and store it in the
  # `queues` hash.
  #
  # ### Notes
  #
  # - The `Configure` struct centralizes the configuration settings for the `JoobQ` system, including Redis connection
  # parameters and queue properties.
  # - It uses environment variables for configuring the Redis client, providing flexibility and ease of configuration
  # in different environments.
  # - The `queue` macro simplifies the process of setting up different types of queues, making the `JoobQ` system
  # adaptable to various job processing requirements.
  struct Configure
    # Loads the logger configuration from the environment variables
    # and sets the default log level to `:trace`.
    Log.setup_from_env(default_level: :trace)

    class_getter instance : Configure = new

    getter queues = {} of String => BaseQueue

    property store : Store = RedisStore.new
    property? stats_enabled : Bool = false
    property default_queue : String = "default"
    property retries : Int32 = 3
    property expires : Time::Span = 3.days
    property timeout : Time::Span = 2.seconds
    property failed_ttl : Time::Span = 3.milliseconds
    property dead_letter_ttl : Time::Span = 7.days

    macro queue(name, workers, kind, throttle_limit = nil)
      {% begin %}
      queues[{{name}}] = JoobQ::Queue({{kind.id}}).new({{name}}, {{workers}}, {{throttle_limit}})
      {% end %}
    end

    def scheduler(&)
      with Scheduler.instance yield
    end
  end
end
