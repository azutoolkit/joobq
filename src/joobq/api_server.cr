require "http/server"
require "json"
require "./api_validation"

module JoobQ
  class APIServer
    Log = ::Log.for("API SERVER")

    def self.start
      new.start
    end

    def start
      server = HTTP::Server.new([APIHandler.new])
      address = "0.0.0.0"
      port = 8080
      Log.info &.emit("Listening on http://#{address}:#{port}")
      server.bind_tcp(address, port)
      server.listen
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

    ENDPOINTS = {
      {method: "POST", path: "/joobq/jobs"} => ->(context : HTTP::Server::Context) do
        context.response.content_type = "application/json"

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

        # Sanitize job data
        sanitized_payload = payload.as_h.dup
        if data = sanitized_payload["data"]?
          sanitized_payload["data"] = APIValidation.sanitize_job_data(data)
        end

        begin
          queue_name = payload["queue"].to_s
          queue = JoobQ[queue_name]

          # Enqueue the job
          jid = queue.add(sanitized_payload.to_json)

          response = {
            status:    "Job enqueued",
            queue:     queue_name,
            job_id:    jid.to_s,
            timestamp: Time.local.to_rfc3339,
          }

          context.response.status = HTTP::Status::CREATED
          context.response.print(response.to_json)
        rescue ex
          Log.error &.emit(
            "Error enqueuing job",
            queue: queue_name,
            error: ex.message || "Unknown error"
          )

          error_response = {
            error:     "Failed to enqueue job",
            message:   ex.message || "Unknown error occurred",
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
        stats = {
          error_counts:        JoobQ.error_monitor.get_error_stats,
          recent_errors_count: JoobQ.error_monitor.get_recent_errors.size,
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
          success = queue.store.move_job_back_to_queue(queue_name)

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
            error: ex.message || "Unknown error"
          )

          response = {
            status:    "error",
            message:   "Failed to reprocess busy jobs for queue '#{queue_name}': #{ex.message}",
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
          pipeline_stats = RedisStore.pipeline_stats
          queue_metrics = RedisStore.instance.get_all_queue_metrics

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
            message:   "Failed to get pipeline health: #{ex.message}",
            timestamp: Time.local.to_rfc3339,
          }
          context.response.status = HTTP::Status::INTERNAL_SERVER_ERROR
          context.response.print(response.to_json)
        end
      end,

      # Pipeline statistics endpoint
      {method: "GET", path: "/joobq/pipeline/stats"} => ->(context : HTTP::Server::Context) do
        begin
          pipeline_stats = RedisStore.pipeline_stats

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
            message:   "Failed to get pipeline statistics: #{ex.message}",
            timestamp: Time.local.to_rfc3339,
          }
          context.response.status = HTTP::Status::INTERNAL_SERVER_ERROR
          context.response.print(response.to_json)
        end
      end,

      # Reset pipeline statistics endpoint
      {method: "POST", path: "/joobq/pipeline/stats/reset"} => ->(context : HTTP::Server::Context) do
        begin
          RedisStore.reset_pipeline_stats

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
            message:   "Failed to reset pipeline statistics: #{ex.message}",
            timestamp: Time.local.to_rfc3339,
          }
          context.response.status = HTTP::Status::INTERNAL_SERVER_ERROR
          context.response.print(response.to_json)
        end
      end,

      # Get retrying jobs (jobs with retrying status in DELAYED_SET)
      {method: "GET", path: "/joobq/jobs/retrying"} => ->(context : HTTP::Server::Context) do
        context.response.content_type = "application/json"

        limit = context.request.query_params["limit"]?.try(&.to_i) || 50
        queue_name = context.request.query_params["queue"]?

        begin
          redis_store = RedisStore.instance
          all_delayed_jobs = redis_store.list_sorted_set_jobs(RedisStore::DELAYED_SET, 1, limit)

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
          end

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
            message:   "Failed to get retrying jobs: #{ex.message}",
            timestamp: Time.local.to_rfc3339,
          }
          context.response.status_code = 500
          context.response.print(response.to_json)
        end
      end,

      # Get dead letter jobs
      {method: "GET", path: "/joobq/jobs/dead"} => ->(context : HTTP::Server::Context) do
        context.response.content_type = "application/json"

        limit = context.request.query_params["limit"]?.try(&.to_i) || 50
        queue_name = context.request.query_params["queue"]?

        begin
          redis_store = RedisStore.instance

          # Get dead letter jobs (from DEAD_LETTER sorted set)
          dead_jobs_raw = redis_store.redis.zrange("joobq:dead_letter", 0, limit - 1)

          dead_jobs = dead_jobs_raw.map(&.as(String)).select do |job_json|
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
          end

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
            message:   "Failed to get dead jobs: #{ex.message}",
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

        begin
          redis_store = RedisStore.instance

          # Find the job in dead letter queue
          dead_jobs = redis_store.redis.zrange("joobq:dead_letter", 0, -1)
          job_found = false
          job_to_retry : String? = nil

          dead_jobs.each do |job_data|
            job_json = job_data.as(String)
            parsed = JSON.parse(job_json)
            if parsed["jid"]?.try(&.as_s) == job_id
              job_found = true
              job_to_retry = job_json
              break
            end
          end

          unless job_found || job_to_retry
            context.response.status_code = 404
            context.response.print({
              error:     "Job not found",
              message:   "Job with ID '#{job_id}' not found in dead letter queue",
              timestamp: Time.local.to_rfc3339,
            }.to_json)
            return
          end

          if job_to_retry
            # Parse the job to get its queue
            parsed_job = JSON.parse(job_to_retry.not_nil!)
            queue_name = parsed_job["queue"]?.try(&.as_s) || "default"

            # Remove from dead letter queue and add back to main queue
            redis_store.redis.pipelined do |pipe|
              pipe.zrem("joobq:dead_letter", job_to_retry.not_nil!)
              pipe.lpush(queue_name, job_to_retry.not_nil!)
            end

            response = {
              status:    "success",
              message:   "Job '#{job_id}' has been moved from dead letter queue back to '#{queue_name}' queue",
              job_id:    job_id,
              queue:     queue_name,
              timestamp: Time.local.to_rfc3339,
            }
            context.response.print(response.to_json)
          end
        rescue ex
          Log.error &.emit("Error retrying dead job", job_id: job_id, error: ex.message)

          response = {
            status:    "error",
            message:   "Failed to retry job: #{ex.message}",
            timestamp: Time.local.to_rfc3339,
          }
          context.response.status_code = 500
          context.response.print(response.to_json)
        end
      end,
    } of NamedTuple(method: String, path: String) => Proc(HTTP::Server::Context, Nil)

    def self.register_endpoint(method, path, handler)
      ENDPOINTS[{method: method, path: path}] = handler
    end

    def call(context : HTTP::Server::Context)
      method = context.request.method
      path = context.request.path
      if handler = ENDPOINTS[{method: method, path: path}]?
        handler.call(context)
      else
        call_next(context)
      end
    end
  end
end
