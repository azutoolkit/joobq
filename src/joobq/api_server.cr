require "http/server"
require "json"

module JoobQ
  class APIServer
    def self.start
      new.start
    end

    def start
      server = HTTP::Server.new([APIHandler.new])
      address = "0.0.0.0"
      port = 8080
      puts "Listening on http://#{address}:#{port}"
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
      if context.request.method == "POST" && context.request.path == "/joobq/jobs"
        if request_body = context.request.body.try(&.gets_to_end)
          response = enqueue(request_body)
          context.response.content_type = "application/json"
          context.response.status = HTTP::Status::CREATED
          context.response.print(response)
        else
          context.response.status_code = 400
          context.response.print("Invalid request")
        end
      elsif context.request.method == "GET" && context.request.path == "/joobq/jobs/registry"
        context.response.content_type = "application/json"
        context.response.print(JoobQ.config.job_registry.json)
      elsif context.request.method == "GET" && context.request.path == "/joobq/metrics"
        metrics = JoobQ.queues.map do |_, queue|
          {queue.name => {
            :total_workers => queue.info[:total_workers],
            :status        => queue.info[:status],
            :metrics       => {
              :enqueued            => queue.info[:enqueued],
              :completed           => queue.info[:completed],
              :retried             => queue.info[:retried],
              :dead                => queue.info[:dead],
              :processing          => queue.info[:processing],
              :running_workers     => queue.info[:running_workers],
              :jobs_per_second     => queue.info[:jobs_per_second],
              :errors_per_second   => queue.info[:errors_per_second],
              :enqueued_per_second => queue.info[:enqueued_per_second],
              :jobs_latency        => queue.info[:jobs_latency].to_s,
              :elapsed_time        => queue.info[:elapsed_time].to_s,
            },
          }}
        end

        context.response.headers["Refresh"] = "5"
        context.response.content_type = "application/json"
        context.response.print(metrics.to_json)
      else
        call_next(context)
      end
    end

    private def enqueue(raw_payload)
      payload = JSON.parse(raw_payload)
      queue_name = payload["queue"].to_s
      queue = JoobQ.queues[queue_name]

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
