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

    def call(context : HTTP::Server::Context)
      method = context.request.method
      path = context.request.path

      case {method: method, path: path}
      when {method: "POST", path: "/joobq/jobs"}         then enqueue_job(context)
      when {method: "GET", path: "/joobq/jobs/registry"} then job_registry(context)
      when {method: "GET", path: "/joobq/queues"}        then queue_metrics(context)
      when {method: "GET", path: "/joobq/metrics"}       then global_metrics(context)
      else                                                    call_next(context)
      end
    end

    private def overtime_series(context)
      context.response.content_type = "application/json"
      metrics = GlobalStats.instance.calculate_stats
      context.response.print(metrics["overtime_series"].to_json)
    end

    private def global_metrics(context)
      context.response.content_type = "application/json"
      metrics = GlobalStats.instance.calculate_stats
      context.response.print(metrics.to_json)
    end

    private def queue_metrics(context)
      metrics = QueueMetrics.new.all_queue_metrics

      context.response.headers["Refresh"] = "5"
      context.response.content_type = "application/json"
      context.response.print(metrics.to_json)
    end

    private def job_registry(context)
      context.response.content_type = "application/json"
      context.response.print(::JoobQ.config.job_registry.json)
    end

    private def enqueue_job(context)
      if request_body = context.request.body.try(&.gets_to_end)
        response = enqueue(request_body)
        context.response.content_type = "application/json"
        context.response.status = HTTP::Status::CREATED
        context.response.print(response)
      else
        context.response.status_code = 400
        context.response.print("Invalid request")
      end
    end

    private def enqueue(raw_payload)
      payload = JSON.parse(raw_payload)
      queue_name = payload["queue"].to_s
      queue = ::JoobQ.queues[queue_name]

      return {error: "Invalid queue name"}.to_json unless queue

      # Assuming there's a method to add a job to the queue
      jid = queue.add(raw_payload)
      response = {
        status: "Job enqueued",
        queue:  queue.name,
        job_id: jid.to_s,
      }

      Log.info &.emit("Job enqueued", queue: queue.name.to_s, job_id: jid.to_s)

      response.to_json
    end
  end
end
