require "http/server"
require "json"

module JoobQ
  class APIServer
    def self.start
      new.start
    end

    def start
      server = http_server
      address = "0.0.0.0"
      port = 8080
      puts "Listening on http://#{address}:#{port}"
      server.bind_tcp(address, port)
      server.listen
    end

    # Define the API server with separate handlers for each endpoint
    private def http_server
      HTTP::Server.new([
        EnqueueHandler.new,
        JobRegistryHandler.new,
        MetricsHandler.new,
      ])
    end
  end

  # Handler for the /enqueue endpoint (POST)
  class EnqueueHandler
    include HTTP::Handler

    def call(context : HTTP::Server::Context)
      if context.request.method == "POST" && context.request.path == "/enqueue"
        request_body = context.request.body.not_nil!
        response = enqueue(request_body.gets_to_end)
        context.response.content_type = "application/json"
        context.response.print(response)
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
      {status: "Job enqueued", queue: queue_name}.to_json
    end
  end

  # Handler for the /jobs/registry endpoint (GET)
  class JobRegistryHandler
    include HTTP::Handler

    def call(context : HTTP::Server::Context)
      if context.request.method == "GET" && context.request.path == "/jobs/registry"
        context.response.content_type = "application/json"
        context.response.print(JoobQ.config.job_registry.json)
      else
        call_next(context)
      end
    end
  end

  # Refactored MetricsHandler for /metrics endpoint (GET), returning JSON
  class MetricsHandler
    include HTTP::Handler

    def call(context : HTTP::Server::Context)
      if context.request.method == "GET" && context.request.path == "/metrics"
        metric_hash = {} of Symbol => Hash(String, String | Int32 | Hash(String, Int32 | Float64))

        metrics = JoobQ.queues.reduce(metric_hash) do |result, (name, queue)|
          result[name] = {
            total_workers: queue.info[:total_workers],
            status:        queue.info[:status],
            metrics:       {
              enqueued:            queue.info[:enqueued],
              completed:           queue.info[:completed],
              retried:             queue.info[:retried],
              dead:                queue.info[:dead],
              processing:          queue.info[:processing],
              running_workers:     queue.info[:running_workers],
              jobs_per_second:     queue.info[:jobs_per_second],
              errors_per_second:   queue.info[:errors_per_second],
              enqueued_per_second: queue.info[:enqueued_per_second],
              jobs_latency:        queue.info[:jobs_latency],
            },
          }
          result
        end

        # Set content type to JSON and print the metrics as JSON
        context.response.content_type = "application/json"
        context.response.print(metrics.to_json)
      else
        call_next(context)
      end
    end
  end
end
