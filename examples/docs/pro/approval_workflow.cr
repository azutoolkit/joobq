require "joobq_pro"
include JoobQPro::Workflows::DSL

struct ReviewInput
  include JSON::Serializable
  getter order_id : Int64
  getter approved : Bool
end

class CompleteApprovedOrder
  def perform(input : ReviewInput, context : JoobQPro::Workflows::ActivityContext) : String
    raise JoobQPro::Workflows::NonRetryableError.new("Order rejected") unless input.approved
    "Approved order #{input.order_id}"
  end
end

OrderReview = workflow "order-review", timeout: 1.minute do
  wait_for :approval, signal: :approve, timeout: 30.seconds
  step :complete, CompleteApprovedOrder,
    input: {order_id: input(:order_id), approved: output(:approval, :approved)}
  query :approval, output(:approval)
end

JoobQ.configure { |config| config.rest_api_enabled = false }
worker = JoobQPro::Workflows::Worker.new(activity_workers: 1, orchestrators: 1, scheduler: false)
begin
  worker.register(OrderReview).start
  id = worker.client.start("order-review", {order_id: 42_i64})
  raise "Signal was not accepted" unless worker.client.signal(id, "approve", {approved: true})
  result = worker.client.result(id, timeout: 10.seconds)
  raise "Unexpected result" unless result["complete"].as_s == "Approved order 42"
  raise "Approval missing" unless worker.client.query(id, "approval")["approved"].as_bool
  puts result["complete"].as_s
ensure
  JoobQPro.shutdown
  JoobQ.shutdown
end
