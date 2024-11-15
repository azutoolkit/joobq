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

  class APIHandler
    include HTTP::Handler

    def call(context : HTTP::Server::Context)
      if context.request.method == "POST" && context.request.path == "/joobq/enqueue"
        if request_body = context.request.body.try(&.gets_to_end)
          response = enqueue(request_body)
          context.response.content_type = "application/json"
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
          {:name => {
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
      {status: "Job enqueued", queue: queue_name, job_id: jid}.to_json
    end
  end
end
