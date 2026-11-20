require "http/server"
require "json"
require "./api_validation"

module JoobQ
  class ManagementHTTPServer < HTTP::Server
    private def handle_client(io : IO)
      if socket = io.as?(Socket)
        socket.read_timeout = 5.seconds
        socket.write_timeout = 5.seconds
      end
      super
    end
  end

  class APIServer
    Log = ::Log.for("API SERVER")

    @@server : HTTP::Server?
    @@server_lock = Sync::Mutex.new

    # Pings the store's Redis for `/readyz`; raises when it does not answer. The ping waits at most REDIS_POOL_TIMEOUT
    # (default 2 s) for a pooled connection, then REDIS_OPERATION_TIMEOUT (default 5 s) bounds the whole operation and
    # REDIS_COMMAND_TIMEOUT (default 5 s) each socket read and write (REDIS_CONNECT_TIMEOUT a new connection).
    @@redis_probe : -> Nil = -> do
      store = JoobQ.store
      raise "store has no Redis" unless store.is_a?(RedisStore)
      store.redis.ping
      nil
    end

    # How long a readiness answer is reused: `/readyz` needs no token, so callers must not be able to spend the Redis
    # pool on it. One probe runs at a time; requests that arrive during it wait for it and share its result.
    READINESS_TTL = 1.second

    @@readiness_lock = Sync::Mutex.new
    @@readiness_cache : {String, Time::Instant}? = nil

    def self.redis_probe : -> Nil
      @@redis_probe
    end

    # Replaces the probe and forgets the cached answer.
    def self.redis_probe=(probe : -> Nil) : Nil
      @@readiness_lock.synchronize do
        @@redis_probe = probe
        @@readiness_cache = nil
      end
    end

    # Forgets the cached Redis answer, so the next readiness check pings again.
    def self.reset_readiness_cache : Nil
      @@readiness_lock.synchronize { @@readiness_cache = nil }
    end

    # Ready when Redis answers and JoobQ is not shutting down. The Redis answer is cached for READINESS_TTL; the
    # shutdown flag is read every time.
    def self.readiness : NamedTuple(ready: Bool, checks: NamedTuple(redis: String, shutdown: Bool))
      redis = cached_redis_status
      shutdown = JoobQ.shut_down?
      {ready: redis == "ok" && !shutdown, checks: {redis: redis, shutdown: shutdown}}
    end

    # Holding the lock across the ping is the single flight: a request that arrives meanwhile waits for the lock and
    # then finds the fresh answer.
    private def self.cached_redis_status : String
      @@readiness_lock.synchronize do
        if (cached = @@readiness_cache) && Time.instant - cached[1] < READINESS_TTL
          next cached[0]
        end
        status = begin
          @@redis_probe.call
          "ok"
        rescue
          "unreachable"
        end
        @@readiness_cache = {status, Time.instant}
        status
      end
    end

    def self.start(address : String = "127.0.0.1", port : Int32 = 8080, *, policy : ManagementPolicy = ManagementPolicy.from_env)
      new.start(address, port, policy: policy)
    end

    # Closes the listener started by `start` (which then returns). Does nothing when none is running.
    def self.stop : Nil
      server = @@server_lock.synchronize do
        current = @@server
        @@server = nil
        current
      end
      server.try { |s| s.close unless s.closed? }
    end

    # Serves until `APIServer.stop` (or `JoobQ.shutdown`). Returns at once, without listening, when the shutdown
    # has begun.
    def start(address : String = "127.0.0.1", port : Int32 = 8080, *, policy : ManagementPolicy = ManagementPolicy.from_env)
      server = ManagementHTTPServer.new([APIHandler.new(policy)])
      Log.info &.emit("Listening on http://#{address}:#{port}")
      server.bind_tcp(address, port)
      # registered after the bind, and the shutdown checked after registering: a `stop` that ran in between
      # either finds the server (and closes it) or has set the flag this sees
      @@server_lock.synchronize { @@server = server }
      if JoobQ.shut_down?
        stop_if_current(server)
        return
      end

      begin
        server.listen
      rescue ex
        raise ex unless server.closed? # closed by `stop` while starting to listen
      end
    end

    private def stop_if_current(server : HTTP::Server) : Nil
      @@server_lock.synchronize { @@server = nil if @@server.same?(server) }
      server.close unless server.closed?
    end
  end

  # The `APIHandler` is a crucial component of the JoobQ library, designed to facilitate the integration of the JoobQ
  # REST API with your HTTP webserver. It provides a set of predefined routes and handlers that allow you to manage
  # job queues, enqueue new jobs, retrieve job statuses, and fetch queue metrics through HTTP requests.
  #
  # #### Key Features:
  # - **Job Enqueuing**: Allows clients to enqueue new jobs into specified queues.
  # - **Job Registry**: Provides endpoints to retrieve the status and details of jobs.
  # - **Queue Metrics**: Offers metrics and statistics about the queues, such as the number of jobs, processing times, etc.
  #
  # #### Usage:
  #
  # To use the `APIHandler`, you need to include it in your HTTP server setup. This involves requiring the necessary
  # libraries, defining your server, and starting it with the `APIHandler` mounted.
  #
  # #### Example:
  #
  # Here's a quick example of how to set up an HTTP server with the `APIHandler`:
  #
  # ```
  # require "http/server"
  # require "json"
  # require "joobq"
  #
  # module MyApp
  #   class Server
  #     def start
  #       server = HTTP::Server.new([JoobQ::APIHandler.new])
  #       address = "0.0.0.0"
  #       port = 8080
  #       puts "Listening on http://#{address}:#{port}"
  #       server.bind_tcp(address, port)
  #       server.listen
  #     end
  #   end
  # end
  #
  # MyApp::Server.new.start
  # ```
  #
  # By following these steps, you can quickly integrate the JoobQ REST API into your application, enabling robust job
  # queue management through simple HTTP requests.
  #
  # ## Mounting the JoobQ REST API with Your HTTP Webserver
  #
  # The `APIHandler` is a built-in component of the JoobQ library that provides a REST API for managing job queues,
  # enqueuing jobs, and fetching queue metrics. It is designed to be mounted on an HTTP webserver to enable clients
  # to interact with the JoobQ library through HTTP requests.
  #
  # To use the `APIHandler` to mount the JoobQ REST API with your own HTTP webserver, follow these steps:
  #
  # ### Step 1: Require Necessary Libraries
  #
  # ```
  # require "http/server"
  # require "json"
  # require "joobq"
  # ```
  #
  # ### Step 2: Define Your HTTP Server
  #
  # Create a new HTTP server and include the `APIHandler` from JoobQ. This handler will manage the routes for enqueuing
  # jobs, retrieving job registry, and fetching queue metrics.
  #
  # ```
  # module MyApp
  #   class Server
  #     def start
  #       server = HTTP::Server.new([JoobQ::APIHandler.new])
  #       address = "0.0.0.0"
  #       port = 8080
  #       puts "Listening on http://#{address}:#{port}"
  #       server.bind_tcp(address, port)
  #       server.listen
  #     end
  #   end
  # end
  # ```
  #
  # ### Step 3: Start the Server
  #
  # Instantiate and start your server. This will bind the server to the specified address and port, and start listening
  # for incoming HTTP requests.
  #
  # ```
  # MyApp::Server.new.start
  # ```
  #
  # ### Complete Example
  #
  # Here is a complete example demonstrating how to set up and start your HTTP server with the JoobQ REST API:
  #
  # ```
  # require "http/server"
  # require "json"
  # require "joobq"
  #
  # module MyApp
  #   class Server
  #     def start
  #       server = HTTP::Server.new([JoobQ::APIHandler.new])
  #       address = "0.0.0.0"
  #       port = 8080
  #       puts "Listening on http://#{address}:#{port}"
  #       server.bind_tcp(address, port)
  #       server.listen
  #     end
  #   end
  # end
  #
  # MyApp::Server.new.start
  # ```
  #
  # ### Additional Configuration
  #
  # You can configure JoobQ by using the `JoobQ.configure` method to set up queues, schedulers, and other settings
  # before starting the server.
  #
  # ```
  # JoobQ.configure do
  #   queue "default", 10, EmailJob
  #   scheduler do
  #     cron("*/1 * * * *") { # Do Something }
  #     every 1.hour, EmailJob, email_address: "john.doe@example.com"
  #   end
  # end
  #
  # MyApp::Server.new.start
  # ```
  #
  # This setup will allow you to use the JoobQ REST API with your own HTTP webserver, enabling you to enqueue jobs,
  # retrieve job registry, and fetch queue metrics through HTTP requests.
  class APIHandler
    include HTTP::Handler

    Log = ::Log.for("API")

    # Entries of the delayed set `GET /joobq/jobs/retrying` scans for retrying jobs, whatever `limit` is.
    RETRYING_SCAN_WINDOW = 1000

    # Enqueues the job a `POST /joobq/jobs` body describes: its `data` object is the job's own JSON, with `retries` from
    # the body when given, put on `queue` (or delayed by `delay` seconds). Raises `JSON::ParseException` or
    # `JSON::SerializableError` when `data` does not fit the queue's job class, and then enqueues nothing. Returns the job id.
    def self.enqueue_posted_job(queue : BaseQueue, payload : JSON::Any) : String
      job = payload["data"].as_h.dup
      if retries = payload["retries"]?
        job["retries"] = retries
        job["max_retries"] = retries
      end

      if delay = payload["delay"]?.try(&.as_i?)
        queue.add_delayed(job.to_json, delay.seconds.from_now)
      else
        queue.add!(job.to_json)
      end
    end

    ENDPOINTS = {
      {method: "POST", path: "/joobq/jobs"} => ->(context : HTTP::Server::Context) do
        context.response.content_type = "application/json"
        # Deprecated: this route enqueues without authentication. `JoobQ.enqueue` behind an authenticated API replaces it.
        context.response.headers["Deprecation"] = "true"

        # Validate content type
        content_type_validation = APIValidation.validate_content_type(context.request.headers["Content-Type"]?)
        unless content_type_validation.success?
          context.response.status_code = 400
          context.response.print(content_type_validation.error_response.to_json)
          return
        end

        # Validate and parse request body
        request_body = context.request.body.try(&.gets_to_end)
        json_validation = APIValidation.validate_json_request(request_body)
        unless json_validation.success?
          context.response.status_code = 400
          context.response.print(json_validation.error_response.to_json)
          return
        end

        payload = json_validation.data.not_nil!

        # Validate job enqueue data
        job_validation = APIValidation.validate_job_enqueue(payload)
        unless job_validation.success?
          context.response.status_code = 422
          context.response.print(job_validation.error_response.to_json)
          return
        end

        begin
          queue_name = payload["queue"].to_s
          queue = JoobQ[queue_name]

          unless queue.job_type == payload["job_type"].to_s
            mismatch = APIValidation::ValidationResult.new(true)
            mismatch.add_error("job_type", "Queue '#{queue_name}' runs #{queue.job_type} jobs, not #{payload["job_type"]}", payload["job_type"], "job_type_mismatch")
            context.response.status_code = 422
            context.response.print(mismatch.error_response.to_json)
            return
          end

          # Strict enqueue: a payload that does not fit the queue's job class is refused here, not dropped after a 201
          jid = APIHandler.enqueue_posted_job(queue, payload)

          response = {
            status:    "Job enqueued",
            queue:     queue_name,
            job_id:    jid,
            timestamp: Time.local.to_rfc3339,
          }

          context.response.status = HTTP::Status::CREATED
          context.response.print(response.to_json)
        rescue ex : JSON::ParseException | JSON::SerializableError
          unfit = APIValidation::ValidationResult.new(true)
          unfit.add_error("data", "Job data does not fit the job class: #{ex.message.to_s.lines.first? || "invalid"}", nil, "invalid_job_data")
          context.response.status_code = 422
          context.response.print(unfit.error_response.to_json)
        rescue ex
          Log.error &.emit(
            "Error enqueuing job",
            queue: queue_name,
            error: ex.message || "Unknown error"
          )

          error_response = {
            error:     "Failed to enqueue job",
            message:   APIValidation.safe_error_message("enqueuing job"),
            timestamp: Time.local.to_rfc3339,
          }

          context.response.status_code = 500
          context.response.print(error_response.to_json)
        end
      end,
      {method: "GET", path: "/joobq/jobs/registry"} => ->(context : HTTP::Server::Context) do
        context.response.content_type = "application/json"
        context.response.print(::JoobQ.config.job_registry.json)
      end,
      {method: "GET", path: "/joobq/health/check"} => ->(context : HTTP::Server::Context) do
        context.response.content_type = "application/json"
        context.response.print({status: "OK"}.to_json)
      end,
      {method: "GET", path: "/joobq/errors/stats"} => ->(context : HTTP::Server::Context) do
        context.response.content_type = "application/json"

        # Get error stats directly from error monitor
        error_counts = JoobQ.error_monitor.get_error_stats
        recent_errors = JoobQ.error_monitor.get_recent_errors(1000)

        stats = {
          error_counts:        error_counts,
          recent_errors_count: recent_errors.size,
          time_window:         JoobQ.error_monitor.time_window.to_s,
        }
        context.response.print(stats.to_json)
      end,
      {method: "GET", path: "/joobq/errors/recent"} => ->(context : HTTP::Server::Context) do
        context.response.content_type = "application/json"

        # Validate query parameters
        query_validation = APIValidation.validate_error_query_params(context.request.query_params)
        unless query_validation.success?
          context.response.status_code = 400
          context.response.print(query_validation.error_response.to_json)
          return
        end

        limit = context.request.query_params["limit"]?.try(&.to_i) || 20

        # Get recent errors directly from error monitor
        recent_errors = JoobQ.error_monitor.get_recent_errors(limit)
        context.response.print(recent_errors.to_json)
      end,
      {method: "GET", path: "/joobq/errors/by-type"} => ->(context : HTTP::Server::Context) do
        context.response.content_type = "application/json"

        # Validate query parameters
        query_validation = APIValidation.validate_error_query_params(context.request.query_params)
        unless query_validation.success?
          context.response.status_code = 400
          context.response.print(query_validation.error_response.to_json)
          return
        end

        error_type = context.request.query_params["type"]?
        unless error_type
          context.response.status_code = 400
          context.response.print({
            error:     "Missing required parameter",
            message:   "The 'type' parameter is required",
            parameter: "type",
            timestamp: Time.local.to_rfc3339,
          }.to_json)
          return
        end

        # Validate error type
        type_validation = APIValidation.validate_error_type(error_type)
        unless type_validation.success?
          context.response.status_code = 400
          context.response.print(type_validation.error_response.to_json)
          return
        end

        errors = JoobQ.error_monitor.get_errors_by_type(error_type)
        context.response.print(errors.to_json)
      end,
      {method: "GET", path: "/joobq/errors/by-queue"} => ->(context : HTTP::Server::Context) do
        context.response.content_type = "application/json"

        # Validate query parameters
        query_validation = APIValidation.validate_error_query_params(context.request.query_params)
        unless query_validation.success?
          context.response.status_code = 400
          context.response.print(query_validation.error_response.to_json)
          return
        end

        queue_name = context.request.query_params["queue"]?
        unless queue_name
          context.response.status_code = 400
          context.response.print({
            error:     "Missing required parameter",
            message:   "The 'queue' parameter is required",
            parameter: "queue",
            timestamp: Time.local.to_rfc3339,
          }.to_json)
          return
        end

        # Validate queue name
        queue_validation = APIValidation.validate_queue_name(queue_name)
        unless queue_validation.success?
          context.response.status_code = 400
          context.response.print(queue_validation.error_response.to_json)
          return
        end

        errors = JoobQ.error_monitor.get_errors_by_queue(queue_name)
        context.response.print(errors.to_json)
      end,
      {method: "POST", path: "/joobq/queues/:queue_name/reprocess"} => ->(context : HTTP::Server::Context) do
        context.response.content_type = "application/json"

        # Extract queue name from path using regex
        path = context.request.path
        queue_match = path.match(/^\/joobq\/queues\/([^\/]+)\/reprocess$/)

        unless queue_match && queue_match[1]?
          context.response.status_code = 400
          context.response.print({
            error:           "Invalid path format",
            message:         "Missing or invalid queue name in path",
            expected_format: "/joobq/queues/{queue_name}/reprocess",
            timestamp:       Time.local.to_rfc3339,
          }.to_json)
          return
        end

        queue_name = queue_match[1]

        # Validate queue name
        queue_validation = APIValidation.validate_queue_name(queue_name)
        unless queue_validation.success?
          context.response.status_code = 400
          context.response.print(queue_validation.error_response.to_json)
          return
        end

        queue = JoobQ[queue_name]
        unless queue
          context.response.status_code = 404
          context.response.print({
            error:     "Queue not found",
            message:   "Queue '#{queue_name}' does not exist",
            queue:     queue_name,
            timestamp: Time.local.to_rfc3339,
          }.to_json)
          return
        end

        begin
          # Reclaims only crashed/stopped processes' jobs; a live worker's in-flight jobs are never taken. A Redis
          # failure reaches the 500 answer below instead of reading as "nothing to reprocess".
          success = if redis_store = queue.store.as?(RedisStore)
                      redis_store.recover_orphaned_processing(queue_name) > 0
                    else
                      queue.store.move_job_back_to_queue(queue_name)
                    end

          if success
            response = {
              status:    "success",
              message:   "Successfully reprocessed busy jobs for queue '#{queue_name}'",
              queue:     queue_name,
              timestamp: Time.local.to_rfc3339,
            }
            context.response.status = HTTP::Status::OK
            context.response.print(response.to_json)
          else
            response = {
              status:    "warning",
              message:   "No busy jobs found to reprocess for queue '#{queue_name}'",
              queue:     queue_name,
              timestamp: Time.local.to_rfc3339,
            }
            context.response.status = HTTP::Status::OK
            context.response.print(response.to_json)
          end
        rescue ex
          Log.error &.emit(
            "Error reprocessing busy jobs for queue",
            queue: queue_name,
            error: ex.message || "Unknown error",
            backtrace: ex.backtrace?.try(&.first(5).join("\n"))
          )

          response = {
            status:    "error",
            message:   APIValidation.safe_error_message("reprocessing busy jobs"),
            queue:     queue_name,
            timestamp: Time.local.to_rfc3339,
          }
          context.response.status = HTTP::Status::INTERNAL_SERVER_ERROR
          context.response.print(response.to_json)
        end
      end,

      # Pipeline health check endpoint
      {method: "GET", path: "/joobq/pipeline/health"} => ->(context : HTTP::Server::Context) do
        begin
          redis_store = RedisStore.instance
          metrics = redis_store.metrics
          pipeline_stats = RedisPipeline.pipeline_stats
          queue_metrics = metrics.get_all_queue_metrics

          # Calculate pipeline health metrics
          success_rate = pipeline_stats.total_pipeline_calls > 0 ? ((pipeline_stats.total_pipeline_calls - pipeline_stats.pipeline_failures).to_f / pipeline_stats.total_pipeline_calls * 100) : 100.0

          health_status = if success_rate >= 99.0
                            "excellent"
                          elsif success_rate >= 95.0
                            "good"
                          elsif success_rate >= 90.0
                            "warning"
                          else
                            "critical"
                          end

          response = {
            status:          "success",
            pipeline_health: {
              status:                 health_status,
              success_rate:           success_rate.round(2),
              total_pipeline_calls:   pipeline_stats.total_pipeline_calls,
              total_commands_batched: pipeline_stats.total_commands_batched,
              average_batch_size:     pipeline_stats.average_batch_size.round(2),
              pipeline_failures:      pipeline_stats.pipeline_failures,
              last_reset:             pipeline_stats.last_reset.to_rfc3339,
              configuration:          {
                enabled:      true,
                batch_size:   JoobQ.config.pipeline_batch_size,
                timeout:      JoobQ.config.pipeline_timeout,
                max_commands: JoobQ.config.pipeline_max_commands,
              },
            },
            queue_metrics: queue_metrics.transform_values do |metrics|
              {
                queue_size:        metrics.queue_size,
                processing_size:   metrics.processing_size,
                failed_count:      metrics.failed_count,
                dead_letter_count: metrics.dead_letter_count,
                processed_count:   metrics.processed_count,
              }
            end,
            timestamp: Time.local.to_rfc3339,
          }

          context.response.status = HTTP::Status::OK
          context.response.print(response.to_json)
        rescue ex
          Log.error &.emit(
            "Error getting pipeline health",
            error: ex.message || "Unknown error"
          )

          response = {
            status:    "error",
            message:   APIValidation.safe_error_message("getting pipeline health"),
            timestamp: Time.local.to_rfc3339,
          }
          context.response.status = HTTP::Status::INTERNAL_SERVER_ERROR
          context.response.print(response.to_json)
        end
      end,

      # Pipeline statistics endpoint
      {method: "GET", path: "/joobq/pipeline/stats"} => ->(context : HTTP::Server::Context) do
        begin
          pipeline_stats = RedisPipeline.pipeline_stats

          response = {
            status:         "success",
            pipeline_stats: {
              total_pipeline_calls:   pipeline_stats.total_pipeline_calls,
              total_commands_batched: pipeline_stats.total_commands_batched,
              average_batch_size:     pipeline_stats.average_batch_size.round(2),
              pipeline_failures:      pipeline_stats.pipeline_failures,
              success_rate:           pipeline_stats.total_pipeline_calls > 0 ? ((pipeline_stats.total_pipeline_calls - pipeline_stats.pipeline_failures).to_f / pipeline_stats.total_pipeline_calls * 100).round(2) : 100.0,
              last_reset:             pipeline_stats.last_reset.to_rfc3339,
              uptime:                 (Time.local - pipeline_stats.last_reset).total_seconds.round(2),
            },
            timestamp: Time.local.to_rfc3339,
          }

          context.response.status = HTTP::Status::OK
          context.response.print(response.to_json)
        rescue ex
          Log.error &.emit(
            "Error getting pipeline statistics",
            error: ex.message || "Unknown error"
          )

          response = {
            status:    "error",
            message:   APIValidation.safe_error_message("getting pipeline statistics"),
            timestamp: Time.local.to_rfc3339,
          }
          context.response.status = HTTP::Status::INTERNAL_SERVER_ERROR
          context.response.print(response.to_json)
        end
      end,

      # Reset pipeline statistics endpoint
      {method: "POST", path: "/joobq/pipeline/stats/reset"} => ->(context : HTTP::Server::Context) do
        begin
          RedisPipeline.reset_pipeline_stats

          response = {
            status:    "success",
            message:   "Pipeline statistics reset successfully",
            timestamp: Time.local.to_rfc3339,
          }

          context.response.status = HTTP::Status::OK
          context.response.print(response.to_json)
        rescue ex
          Log.error &.emit(
            "Error resetting pipeline statistics",
            error: ex.message || "Unknown error"
          )

          response = {
            status:    "error",
            message:   APIValidation.safe_error_message("resetting pipeline statistics"),
            timestamp: Time.local.to_rfc3339,
          }
          context.response.status = HTTP::Status::INTERNAL_SERVER_ERROR
          context.response.print(response.to_json)
        end
      end,

      # Get retrying jobs (jobs with retrying status in DELAYED_SET)
      {method: "GET", path: "/joobq/jobs/retrying"} => ->(context : HTTP::Server::Context) do
        context.response.content_type = "application/json"

        query_validation = APIValidation.validate_list_query_params(context.request.query_params)
        unless query_validation.success?
          context.response.status_code = 400
          context.response.print(query_validation.error_response.to_json)
          return
        end

        limit = context.request.query_params["limit"]?.try(&.to_i) || 50
        queue_name = context.request.query_params["queue"]?

        begin
          redis_store = RedisStore.instance

          # Scan a fixed window of the delayed set (the retrying jobs among them are returned, at most `limit`)
          all_delayed_jobs = redis_store.list_sorted_set_jobs(RedisStore::DELAYED_SET, 1, RETRYING_SCAN_WINDOW)

          # Filter for retrying jobs (jobs with retrying status)
          retrying_jobs = all_delayed_jobs.select do |job_json|
            begin
              parsed = JSON.parse(job_json)
              status = parsed["status"]?.try(&.as_s)
              job_queue = parsed["queue"]?.try(&.as_s)

              # Check if status is Retrying and optionally filter by queue
              is_retrying = status == "Retrying"
              matches_queue = queue_name.nil? || job_queue == queue_name

              is_retrying && matches_queue
            rescue
              false
            end
          end.first(limit)

          response = {
            status:    "success",
            jobs:      retrying_jobs.map { |j| JSON.parse(j) },
            count:     retrying_jobs.size,
            timestamp: Time.local.to_rfc3339,
          }

          context.response.print(response.to_json)
        rescue ex
          Log.error &.emit("Error getting retrying jobs", error: ex.message)

          response = {
            status:    "error",
            message:   APIValidation.safe_error_message("getting retrying jobs"),
            timestamp: Time.local.to_rfc3339,
          }
          context.response.status_code = 500
          context.response.print(response.to_json)
        end
      end,

      # Get dead letter jobs
      {method: "GET", path: "/joobq/jobs/dead"} => ->(context : HTTP::Server::Context) do
        context.response.content_type = "application/json"

        query_validation = APIValidation.validate_list_query_params(context.request.query_params)
        unless query_validation.success?
          context.response.status_code = 400
          context.response.print(query_validation.error_response.to_json)
          return
        end

        limit = context.request.query_params["limit"]?.try(&.to_i) || 50
        queue_name = context.request.query_params["queue"]?

        begin
          redis_store = RedisStore.instance

          # Read a fixed window of the dead letter set, never more than the largest `limit`
          cached_dead_jobs = redis_store.redis.zrange(Keys::DEAD_LETTER, 0, APIValidation::MAX_LIST_LIMIT - 1).map(&.as(String))

          dead_jobs = cached_dead_jobs.select do |job_json|
            if queue_name
              begin
                parsed = JSON.parse(job_json)
                job_queue = parsed["queue"]?.try(&.as_s)
                job_queue == queue_name
              rescue
                false
              end
            else
              true
            end
          end.first(limit)

          response = {
            status:    "success",
            jobs:      dead_jobs.map { |j| JSON.parse(j) },
            count:     dead_jobs.size,
            timestamp: Time.local.to_rfc3339,
          }

          context.response.print(response.to_json)
        rescue ex
          Log.error &.emit("Error getting dead jobs", error: ex.message)

          response = {
            status:    "error",
            message:   APIValidation.safe_error_message("getting dead jobs"),
            timestamp: Time.local.to_rfc3339,
          }
          context.response.status_code = 500
          context.response.print(response.to_json)
        end
      end,

      # Retry a dead job (move from dead letter queue back to main queue)
      {method: "POST", path: "/joobq/jobs/:job_id/retry"} => ->(context : HTTP::Server::Context) do
        context.response.content_type = "application/json"

        # Extract job ID from path
        path = context.request.path
        job_match = path.match(/^\/joobq\/jobs\/([^\/]+)\/retry$/)

        unless job_match && job_match[1]?
          context.response.status_code = 400
          context.response.print({
            error:     "Invalid path format",
            message:   "Missing or invalid job ID in path",
            timestamp: Time.local.to_rfc3339,
          }.to_json)
          return
        end

        job_id = job_match[1]

        # Validate job ID format to prevent path traversal
        job_validation = APIValidation.validate_job_id(job_id)
        unless job_validation.success?
          context.response.status_code = 400
          context.response.print(job_validation.error_response.to_json)
          return
        end

        begin
          dlq = DeadLetterQueue.new
          entry = dlq.find(job_id)
          unless entry
            context.response.status_code = 404
            context.response.print({
              error:     "Job not found",
              message:   "Job with ID '#{job_id}' not found in dead letter queue",
              timestamp: Time.local.to_rfc3339,
            }.to_json)
            return
          end

          outcome = dlq.redrive([job_id])
          if outcome.succeeded == 1
            context.response.print({
              status:    "success",
              message:   "Job '#{job_id}' has been moved from dead letter queue back to '#{entry.queue}' queue",
              job_id:    job_id,
              queue:     entry.queue,
              timestamp: Time.local.to_rfc3339,
            }.to_json)
          else
            unredrivable = !outcome.unredrivable.empty?
            context.response.status_code = unredrivable ? 422 : 409
            context.response.print({
              error:     unredrivable ? "Job cannot be retried" : "Job was already handled",
              message:   unredrivable ? "The stored job could not be parsed, so it cannot run again" : "Another operator moved this job first",
              timestamp: Time.local.to_rfc3339,
            }.to_json)
          end
        rescue ex
          Log.error &.emit("Error retrying dead job", job_id: job_id, error: ex.message)

          response = {
            status:    "error",
            message:   APIValidation.safe_error_message("retrying job"),
            timestamp: Time.local.to_rfc3339,
          }
          context.response.status_code = 500
          context.response.print(response.to_json)
        end
      end,
    } of NamedTuple(method: String, path: String) => Proc(HTTP::Server::Context, Nil)

    # Liveness and readiness probes, answered without the management policy (see `call`).
    PROBES = {
      "/healthz" => ->(context : HTTP::Server::Context) { probe_answer(context, 200, {status: "ok"}.to_json) },
      "/readyz"  => ->(context : HTTP::Server::Context) do
        readiness = APIServer.readiness
        status = readiness[:ready] ? "ready" : "not_ready"
        probe_answer(context, readiness[:ready] ? 200 : 503, {status: status, checks: readiness[:checks]}.to_json)
      end,
    }

    private def self.probe_answer(context : HTTP::Server::Context, status : Int32, body : String) : Nil
      context.response.status_code = status
      context.response.headers["Cache-Control"] = "no-store"
      context.response.content_type = "application/json"
      context.response.content_length = body.bytesize
      context.response.print(body) unless context.request.method == "HEAD"
    end

    @@param_routes : Array({String, Array(String), Proc(HTTP::Server::Context, Nil)})?

    def self.register_endpoint(method, path, handler)
      ENDPOINTS[{method: method, path: path}] = handler
      @@param_routes = nil
    end

    # Routes with ":param" segments, split once instead of on every request.
    protected def self.param_routes
      @@param_routes ||= ENDPOINTS.compact_map do |key, handler|
        {key[:method], key[:path].split('/'), handler} if key[:path].includes?(':')
      end
    end

    def initialize(@policy : ManagementPolicy? = nil, *, unsafe_no_auth : Bool = false)
      @policy = ManagementPolicy.from_env unless @policy || unsafe_no_auth
    end

    def call(context : HTTP::Server::Context)
      # Orchestrator probes carry no token, and their answers reveal only liveness, whether Redis answers and
      # shutdown: exactly these two paths, on GET or HEAD, skip the policy. Every other request is authorized below.
      if (probe = PROBES[context.request.path]?) && context.request.method.in?("GET", "HEAD")
        return probe.call(context)
      end
      return if (policy = @policy) && !policy.authorize(context)
      method = context.request.method
      path = context.request.path
      if handler = ENDPOINTS[{method: method, path: path}]? || match_param_route(method, path)
        handler.call(context)
      else
        call_next(context)
      end
    end

    # Finds a handler registered with ":param" segments, e.g. "/joobq/jobs/:job_id/retry".
    private def match_param_route(method : String, path : String)
      segments = path.split('/')
      self.class.param_routes.each do |route_method, pattern, handler|
        next unless route_method == method && pattern.size == segments.size

        return handler if pattern.zip(segments).all? { |part, seg| part.starts_with?(':') ? !seg.empty? : part == seg }
      end
      nil
    end
  end
end
