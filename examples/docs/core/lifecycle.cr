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

# The management API accepts a reader-only policy; it does not require all roles.
ENV["JOOBQ_API_READER_TOKEN"] = "docs-reader-only-token-32-bytes-long"
policy = JoobQ::ManagementPolicy.from_env
ENV.delete("JOOBQ_API_READER_TOKEN")
headers = HTTP::Headers{"Authorization" => "Bearer docs-reader-only-token-32-bytes-long"}
read = HTTP::Server::Context.new(HTTP::Request.new("GET", "/stats", headers), HTTP::Server::Response.new(IO::Memory.new))
raise "Reader token denied inspection" unless policy.authorize(read)
write = HTTP::Server::Context.new(HTTP::Request.new("POST", "/retry", headers), HTTP::Server::Response.new(IO::Memory.new))
raise "Reader token authorized mutation" if policy.authorize(write)
raise "Expected forbidden mutation" unless write.response.status_code == 403

# The Redis DLQ writer accepts expiration_time but does not enforce retention.
retained = FailingOrderJob.new
retained.queue = "docs-retention"
JoobQ::RedisStore.instance.mark_as_dead(retained, 1_i64)
sleep 1100.milliseconds
retention_dlq = JoobQ::DeadLetterQueue.new
raise "Expected retained record after supplied expiry" unless retention_dlq.count("docs-retention") == 1
raise "Unexpected Redis DLQ key expiry" unless JoobQ::RedisStore.instance.redis.ttl(JoobQ::DeadLetterQueue::KEY) == -1
raise "Retention probe cleanup failed" unless retention_dlq.purge([retained.jid.to_s]).succeeded == 1

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
