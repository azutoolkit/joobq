require "joobq"

struct GenerateReportJob
  include JoobQ::Job
  @queue = "reports"
  getter report_id : Int64

  def initialize(@report_id : Int64)
  end

  def perform
    puts "Generated report #{report_id}"
  end
end

# The recurring callback only admits work. Queue workers perform the report.
struct EnqueueReportJob
  include JoobQ::Job
  getter report_id : Int64

  def initialize(@report_id : Int64)
  end

  def perform
    GenerateReportJob.enqueue(report_id: report_id)
  end
end

JoobQ.configure do |config|
  config.rest_api_enabled = false
  config.worker_batch_size = 1
  queue "reports", 2, GenerateReportJob
end

# Starts immediately; own this registration in one scheduler process only.
EnqueueReportJob.schedule(every: 1.minute, report_id: 42_i64)
JoobQ.forge
