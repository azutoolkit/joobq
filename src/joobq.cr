require "redis"
require "json"
require "uuid"
require "uuid/json"
require "log"
require "cron_parser"
require "./joobq/store"
require "./joobq/**"

# ### Module `JoobQ`
#
# The main `JoobQ` module, which acts as the central orchestrator for a job
# queueing system. This module integrates various components like job queueing, scheduling, statistics tracking, and
# logging. Here's a detailed documentation of the `JoobQ` module:
#
# #### Overview
#
# The `JoobQ` module is the core module of a job queue system designed in Crystal. It sets up and manages the entire
# job processing environment, including configuration, queue management, scheduling, and statistics.
#
# #### Constants
#
# - `REDIS`: Initialized with the Redis client instance from `Configure.instance`, used for all Redis operations
# within the module.
#
# #### Initialization and Configuration
#
# - `Log.for("JoobQ")`: Initializes logging for the `JoobQ` system.
# - `Log.setup_from_env`: Sets up logging configuration from environment variables.
#
# #### Methods
#
# - `configure`: Provides a way to configure the `JoobQ` system. Yields to a block with `Configure.instance`
#   for setting up configurations.
# - `config`: Returns the configuration instance (`Configure.instance`).
# - `queues`: Returns the hash of queues set up in the configuration.
# - `statistics`: Returns an instance of the `Statistics` for tracking and managing statistical data.
# - `push(job)`: Adds a job to its respective queue in Redis and logs the action. Returns the job's unique
#   identifier (`jid`).
# - `scheduler`: Returns an instance of the `Scheduler` for managing job scheduling.
# - `[](name : String)`: A shorthand method to access a specific queue by name from the configured queues.
# - `reset`: Clears the Redis database and re-creates the statistical series.
# - `forge`: The main method to boot the `JoobQ` system. It initializes the statistics, starts the scheduler,
#   starts all queues, and logs the initialization process.
#
# #### Usage
#
# - To initialize and start the `JoobQ` system, call `JoobQ.forge`.
# - Use `JoobQ.configure` to set up system configurations.
# - Jobs can be pushed to the queue using `JoobQ.add(job)`.
# - Access specific queues or the scheduler as needed.
#
# ### Notes
#
# - The `JoobQ` module brings together different components like queues, scheduler, and statistics into a cohesive system.
# - The use of a centralized Redis client ensures consistent database interactions.
# - Logging and statistics creation are integral parts of the module, facilitating monitoring and debugging.
# - The module's design allows for flexible configuration and easy management of job queues.
module JoobQ
  extend self

  def config
    Configure.instance
  end

  def configure(&)
    with config yield config
  end

  def store
    config.store
  end

  def reset
    store.reset
  end

  def statistics
    JoobQ::GlobalStats.calculate_stats(queues)
  end

  def queues
    config.queues
  end

  def add(job)
    store.enqueue(job)
  end

  def scheduler
    Scheduler.instance
  end

  def [](name : String)
    queues[name]
  end

  def forge
    Log.info { "JoobQ starting..." }
    scheduler.run

    queues.each do |key, queue|
      Log.info { "JoobQ starting #{key} queue..." }
      queue.start
    end

    Log.info { "JoobQ initialized and waiting for Jobs..." }

    Log.info { "Rest API Enabled: #{config.rest_api_enabled?}" }
    APIServer.start

    sleep
  end
end
