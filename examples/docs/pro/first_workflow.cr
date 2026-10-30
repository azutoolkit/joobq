require "joobq_pro"
include JoobQPro::Workflows

struct OrderInput
  include JSON::Serializable
  getter order_id : Int64
end

class ProcessOrder
  def perform(input : OrderInput, context : ActivityContext) : String
    "Processed order #{input.order_id}"
  end
end

register_activity ProcessOrder

JoobQ.configure { |config| config.rest_api_enabled = false }
definition = Definition.new("process-order", [
  Step.activity("process", "ProcessOrder", input: JSON.parse(%({"order_id":"${input.order_id}"}))),
]).validate!

worker = Worker.new(activity_workers: 1, orchestrators: 1, scheduler: false)
worker.register(definition).start
begin
  id = worker.client.start("process-order", {order_id: 42_i64})
  result = worker.client.result(id, timeout: 10.seconds)
  puts result["process"].as_s
ensure
  JoobQPro.shutdown
  JoobQ.shutdown
end
