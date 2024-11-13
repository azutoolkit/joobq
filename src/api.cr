require "http/server"
require "json"
require "./joobq"

class JobEnqueuer
  def self.enqueue(raw_payload)
    payload = JSON.parse(raw_payload)
    queue_name = payload["queue"].to_s
    puts queue_name
    queue = JoobQ.queues[queue_name]
    return { error: "Invalid queue name" }.to_json unless queue
    # jid = queue.push(raw_payload)
    # { status: "Job enqueued", queue: queue, job: jid }.to_json
  end
end


# Define the API server
server = HTTP::Server.new do |context|
  if context.request.method == "POST" && context.request.path == "/enqueue"
    request_body = context.request.body.not_nil!
    response = JobEnqueuer.enqueue(request_body.gets_to_end)

    context.response.content_type = "application/json"
    context.response.print(response)

  elsif context.request.method == "GET" && context.request.path == "/jobs/registry"
    context.response.content_type = "application/json"

    context.response.print(JoobQ.config.job_registry.json)
  else
    context.response.status_code = 404
    context.response.print("Not Found")
  end
end

address = "0.0.0.0"
port = 8080
puts "Listening on http://#{address}:#{port}"
server.bind_tcp(address, port)
server.listen
