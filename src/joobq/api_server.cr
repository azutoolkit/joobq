require "http/server"
require "json"

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
        if request_body = context.request.body.try(&.gets_to_end)
          payload = JSON.parse(request_body)
          queue_name = payload["queue"].to_s
          queue = JoobQ[queue_name]
          return {error: "Invalid queue name"}.to_json unless queue

          # Assuming there's a method to add a job to the queue
          jid = queue.add(request_body)

          response = {
            status: "Job enqueued",
            queue:  queue_name,
            job_id: jid.to_s,
          }
          context.response.content_type = "application/json"
          context.response.status = HTTP::Status::CREATED
          context.response.print(response.to_json)
        else
          context.response.status_code = 400
          context.response.print("Invalid request")
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
        limit = context.request.query_params["limit"]?.try(&.to_i) || 20
        recent_errors = JoobQ.error_monitor.get_recent_errors(limit)
        context.response.print(recent_errors.to_json)
      end,
      {method: "GET", path: "/joobq/errors/by-type"} => ->(context : HTTP::Server::Context) do
        context.response.content_type = "application/json"
        error_type = context.request.query_params["type"]?
        if error_type
          errors = JoobQ.error_monitor.get_errors_by_type(error_type)
          context.response.print(errors.to_json)
        else
          context.response.status_code = 400
          context.response.print({error: "Missing 'type' parameter"}.to_json)
        end
      end,
      {method: "GET", path: "/joobq/errors/by-queue"} => ->(context : HTTP::Server::Context) do
        context.response.content_type = "application/json"
        queue_name = context.request.query_params["queue"]?
        if queue_name
          errors = JoobQ.error_monitor.get_errors_by_queue(queue_name)
          context.response.print(errors.to_json)
        else
          context.response.status_code = 400
          context.response.print({error: "Missing 'queue' parameter"}.to_json)
        end
      end,
      {method: "POST", path: "/joobq/queues/:queue_name/reprocess"} => ->(context : HTTP::Server::Context) do
        context.response.content_type = "application/json"

        # Extract queue name from path using regex
        path = context.request.path
        queue_match = path.match(/^\/joobq\/queues\/([^\/]+)\/reprocess$/)

        unless queue_match && queue_match[1]?
          context.response.status_code = 400
          context.response.print({error: "Missing or invalid queue name in path"}.to_json)
          return
        end

        queue_name = queue_match[1]

        queue = JoobQ[queue_name]
        unless queue
          context.response.status_code = 404
          context.response.print({error: "Queue '#{queue_name}' not found"}.to_json)
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
