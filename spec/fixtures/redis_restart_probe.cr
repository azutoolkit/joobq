# Storage durability probe for scripts/redis_restart_smoke.py, never the shared test Redis.
require "../../src/joobq"

class RestartProbeJob
  include JoobQ::Job
  property number : Int32

  def initialize(@number)
    @queue = "restart_probe"
  end

  def perform
  end
end

store = JoobQ::RedisStore.new
ledger = JoobQ::Delivery::Ledger.new(store.redis, "probe", "restart")
case ARGV.first?
when "seed"
  jobs = Array(JoobQ::Job).new(1000) { |i| RestartProbeJob.new(i).as(JoobQ::Job) }
  store.enqueue_batch(jobs)
  claimed = store.dequeue_batch("restart_probe", RestartProbeJob, 10)
  raise "claim count mismatch" unless claimed.size == 10
  100.times do |i|
    result = ledger.admit("request-#{i}", "payload-#{i}")
    raise "admission failed" unless result.code.accepted?
  end
  50.times do |i|
    claim = ledger.claim("before-crash", i < 20 ? 50.milliseconds : 30.seconds).not_nil!
    state = case i
            when 20...30 then JoobQ::Delivery::State::Scheduled
            when 30...40 then JoobQ::Delivery::State::Completed
            when 40...50 then JoobQ::Delivery::State::Dead
            else              next
            end
    raise "settlement failed" unless ledger.settle(claim, state, 5.minutes).applied?
  end
when "verify"
  ready = store.redis.lrange("restart_probe", 0, -1)
  # The seed ran in another process, so its claimed jobs are in its own list (joobq:processing:restart_probe:<owner>).
  processing = [] of Redis::RedisValue
  cursor = 0_i64
  loop do
    result = store.redis.scan(cursor, match: "joobq:processing:restart_probe*", count: 100)
    cursor = result[0].as(String).to_i64
    result[1].as(Array).each do |key|
      key_str = key.as(String)
      processing.concat(store.redis.lrange(key_str, 0, -1)) if key_str == "joobq:processing:restart_probe" || key_str.starts_with?("joobq:processing:restart_probe:")
    end
    break if cursor == 0
  end
  raise "lost ready jobs" unless ready.size == 990
  raise "lost claimed jobs" unless processing.size == 10
  numbers = (ready + processing).map { |raw| RestartProbeJob.from_json(raw.as(String)).number }.sort
  raise "missing or duplicate payloads" unless numbers == (0...1000).to_a
  states = Hash(JoobQ::Delivery::State, Int32).new(0)
  100.times do |i|
    record = ledger.resolve("request-#{i}") || raise "lost receipt"
    raise "corrupted payload" unless record.payload == "payload-#{i}"
    states[record.state] += 1
  end
  raise "lost canonical states" unless states == {
                                         JoobQ::Delivery::State::Ready => 50, JoobQ::Delivery::State::Leased => 20,
                                         JoobQ::Delivery::State::Scheduled => 10, JoobQ::Delivery::State::Completed => 10,
                                         JoobQ::Delivery::State::Dead => 10,
                                       }
  sleep 60.milliseconds
  cursor = "0"
  loop do
    cursor = ledger.repair(cursor)
    break if cursor == "0"
  end
  raise "expired claim not recovered" unless store.redis.zcard(ledger.ready_key) == 80
  raise "lease index not repaired" unless store.redis.zcard(ledger.leases_key) == 0
  puts "PASS: 100 canonical delivery records survived SIGKILL; 20 expired leases recovered"
  puts "PASS: 990 queued + 10 claimed payloads survived Redis SIGKILL/AOF restart"
else
  raise "expected seed or verify"
end
