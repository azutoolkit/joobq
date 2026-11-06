require "joobq"

struct SendWelcomeEmailJob
  include JoobQ::Job

  @queue = "emails"
  getter recipient : String

  def initialize(@recipient : String)
  end

  def perform
    smtp = ENV["SMTP_HOST"]? || raise "SMTP_HOST is not set"
    puts "Sent welcome email to #{recipient} via #{smtp}"
  end
end

JoobQ.configure do |config|
  config.rest_api_enabled = false
  config.retries = 1 # one retry, so a failure reaches the dead letters in seconds
  queue "emails", 2, SendWelcomeEmailJob
end

JoobQ::WorkerRegistry.new.start # lists this process on the console's Workers page
SendWelcomeEmailJob.enqueue(recipient: "ada@example.com") if ARGV.includes?("--enqueue")
puts "Worker ready"
JoobQ.forge
