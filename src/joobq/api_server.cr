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
        sanitized_payload = payload.dup
        if data = sanitized_payload["data"]?
          sanitized_payload["data"] = APIValidation.sanitize_job_data(data)
        end

        begin
          queue_name = payload["queue"].to_s
          queue = JoobQ[queue_name]

          # Enqueue the job
          jid = queue.add(sanitized_payload.to_json)

          response = {
            status: "Job enqueued",
            queue: queue_name,
            job_id: jid.to_s,
            timestamp: Time.local.to_rfc3339
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
            error: "Failed to enqueue job",
            message: ex.message || "Unknown error occurred",
            timestamp: Time.local.to_rfc3339
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
          error_counts: JoobQ.error_monitor.get_error_stats,
          recent_errors_count: JoobQ.error_monitor.get_recent_errors.size,
          time_window: JoobQ.error_monitor.time_window.to_s
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
            error: "Missing required parameter",
            message: "The 'type' parameter is required",
            parameter: "type",
            timestamp: Time.local.to_rfc3339
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

        limit = context.request.query_params["limit"]?.try(&.to_i) || 20
        errors = JoobQ.error_monitor.get_errors_by_type(error_type, limit)
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
            error: "Missing required parameter",
            message: "The 'queue' parameter is required",
            parameter: "queue",
            timestamp: Time.local.to_rfc3339
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

        limit = context.request.query_params["limit"]?.try(&.to_i) || 20
        errors = JoobQ.error_monitor.get_errors_by_queue(queue_name, limit)
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
            error: "Invalid path format",
            message: "Missing or invalid queue name in path",
            expected_format: "/joobq/queues/{queue_name}/reprocess",
            timestamp: Time.local.to_rfc3339
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
            error: "Queue not found",
            message: "Queue '#{queue_name}' does not exist",
            queue: queue_name,
            timestamp: Time.local.to_rfc3339
          }.to_json)
          return
        end

        begin
          success = queue.store.move_job_back_to_queue(queue_name)

          if success
            response = {
              status: "success",
              message: "Successfully reprocessed busy jobs for queue '#{queue_name}'",
              queue: queue_name,
              timestamp: Time.local.to_rfc3339
            }
            context.response.status = HTTP::Status::OK
            context.response.print(response.to_json)
          else
            response = {
              status: "warning",
              message: "No busy jobs found to reprocess for queue '#{queue_name}'",
              queue: queue_name,
              timestamp: Time.local.to_rfc3339
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
            status: "error",
            message: "Failed to reprocess busy jobs for queue '#{queue_name}': #{ex.message}",
            queue: queue_name,
            timestamp: Time.local.to_rfc3339
          }
          context.response.status = HTTP::Status::INTERNAL_SERVER_ERROR
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
