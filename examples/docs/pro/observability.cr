require "joobq_pro"

struct ObservedOrderJob
  include JoobQ::Job
  @queue = "docs-observed"

  def initialize
  end

  def perform
  end
end

JoobQ::QueueFactory.register_job_type(ObservedOrderJob)
JoobQ.configure do |config|
  config.rest_api_enabled = false
  config.middlewares.unshift(JoobQPro::Middleware::Metrics.instance)
  config.queue_configs["docs-observed"] = {job_class_name: "ObservedOrderJob", workers: 1, throttle: nil}
end

finished = Channel(Nil).new(1)
spawn do
  JoobQ.forge(trap_signals: false)
  finished.send(nil)
end

begin
  ObservedOrderJob.enqueue
  metrics = JoobQPro::Middleware::Metrics.instance
  deadline = Time.instant + 10.seconds
  until metrics.metrics_by_queue["docs-observed"]?.try(&.completed.get) == 1
    raise "Completion metric did not arrive" if Time.instant >= deadline
    sleep 20.milliseconds
  end
  raise "Worker still marked busy" unless metrics.metrics_by_queue["docs-observed"].busy.get == 0
  metrics.metrics_collector.collect_and_store_metrics
ensure
  pro_stopped = JoobQPro.shutdown(5.seconds)
  JoobQ.shutdown(5.seconds)
  select
  when finished.receive
  when timeout(6.seconds)
    raise "Worker did not stop"
  end
  raise "Metrics loops did not stop" unless pro_stopped
end
puts "PASS completion metrics collection shutdown"
