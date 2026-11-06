require "joobq"

struct ExportReportJob
  include JoobQ::Job

  @queue = "exports"
  getter report_id : Int32

  def initialize(@report_id : Int32)
  end

  def perform
    puts "Exported report #{report_id}"
  end
end

JoobQ.configure do |config|
  config.rest_api_enabled = false
  config.worker_batch_size = 1
  queue "exports", 1, ExportReportJob
end

# Enqueued before any worker runs: 1, then 2, then 3.
(1..3).each { |id| ExportReportJob.enqueue(report_id: id) }
JoobQ.forge
