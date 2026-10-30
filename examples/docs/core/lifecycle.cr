require "joobq"

struct FailingOrderJob
  include JoobQ::Job
  @queue = "docs-failure"
  @@attempts = Atomic(Int32).new(0)
  @@repaired = Atomic(Bool).new(false)

  def initialize
  end

  def self.attempts
    @@attempts.get
  end

  def self.repair
    @@repaired.set(true)
  end

  def perform
    @@attempts.add(1)
    raise "Intentional documentation failure" unless @@repaired.get
  end
end

def wait_until(& : -> Bool)
  deadline = Time.instant + 15.seconds
  until yield
    raise "Documentation lifecycle timed out" if Time.instant >= deadline
    sleep 20.milliseconds
  end
end

JoobQ.configure do |config|
  config.rest_api_enabled = false
  config.retries = 1
  queue "docs-failure", 1, FailingOrderJob
end

finished = Channel(Nil).new(1)
spawn do
  JoobQ.forge(trap_signals: false)
  finished.send(nil)
end

begin
  FailingOrderJob.delay(for: 50.milliseconds)
  dlq = JoobQ::DeadLetterQueue.new
  wait_until { dlq.count("docs-failure") == 1 }
  raise "Expected initial attempt plus one retry" unless FailingOrderJob.attempts == 2
  entry = dlq.page(queue: "docs-failure").first
  raise "Expected redrivable payload" unless entry.redrivable?
  FailingOrderJob.repair
  raise "Selected replay failed" unless dlq.redrive([entry.jid]).succeeded == 1
  wait_until { FailingOrderJob.attempts == 3 }
  raise "DLQ entry retained after replay" unless dlq.count("docs-failure") == 0
ensure
  JoobQ.shutdown(5.seconds)
  select
  when finished.receive
  when timeout(6.seconds)
    raise "Worker did not stop"
  end
  raise "Shutdown abandoned work" unless JoobQ.abandoned_jobs == 0
end
puts "PASS delayed retry DLQ replay shutdown"
