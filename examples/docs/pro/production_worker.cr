require "joobq_pro"
include JoobQPro::Workflows::DSL

class ProcessOrder
  def perform(order_id : Int64, context : JoobQPro::Workflows::ActivityContext) : String
    "Processed order #{order_id}"
  end
end

Orders = workflow "orders", timeout: 1.minute do
  step :process, ProcessOrder, timeout: 10.seconds
end

JoobQ.configure { |config| config.rest_api_enabled = false }
stopping = Channel(Nil).new(1)
[Signal::INT, Signal::TERM].each do |signal|
  signal.trap do
    select
    when stopping.send(nil)
    else
      # A stop is already pending; let the shutdown budget finish.
    end
  end
end

worker = JoobQPro::Workflows::Worker.new(activity_workers: 2, orchestrators: 1, scheduler: false)
clean = false
begin
  worker.register(Orders).start
  puts "Worker ready"
  STDOUT.flush
  stopping.receive
ensure
  begin
    clean = JoobQPro.shutdown(20.seconds)
  ensure
    JoobQ.shutdown(10.seconds)
  end
end
exit(clean && JoobQ.abandoned_jobs == 0 ? 0 : 3)
