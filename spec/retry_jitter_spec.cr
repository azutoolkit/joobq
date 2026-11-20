require "./spec_helper"

module JoobQ
  describe "ExponentialBackoff full jitter" do
    max_ms = 3_600_000_i64 # ExponentialBackoff's MAX_DELAY_MS (1 hour)

    before_each { JoobQ.reset }
    after_each { JoobQ.config.retry_jitter = true }

    it "caps and clamps the ceiling" do
      {-1 => 1_000_i64, 0 => 1_000_i64, 1 => 2_000_i64, 5 => 32_000_i64, 22 => max_ms, 50 => max_ms}.each do |attempt, ms|
        ExponentialBackoff.ceiling_ms(attempt).should eq ms
      end
    end

    it "draws uniformly within MIN_DELAY_MS..ceiling, deterministically per seed" do
      ceiling = ExponentialBackoff.ceiling_ms(5)
      random = Random.new(42)
      samples = Array.new(500) { ExponentialBackoff.delay_ms(5, random) }
      samples.all? { |d| d >= ExponentialBackoff::MIN_DELAY_MS && d <= ceiling }.should be_true
      samples.uniq.size.should be > 1
      (samples.sum / samples.size.to_f).should be_close((1_000 + ceiling) / 2.0, (1_000 + ceiling) / 2.0 * 0.2)
      again = Random.new(42)
      Array.new(500) { ExponentialBackoff.delay_ms(5, again) }.should eq samples
    end

    it "never waits less than 1 second, so attempt 0 is exactly 1 second" do
      ExponentialBackoff::MIN_DELAY_MS.should eq 1_000_i64
      random = Random.new(7)
      Array.new(200) { ExponentialBackoff.delay_ms(0, random) }.uniq.should eq [1_000_i64]
      Array.new(2_000) { ExponentialBackoff.delay_ms(1, random) }.min.should be >= 1_000_i64
    end

    it "is jittered by default and equals the ceiling when jitter is off" do
      JoobQ.config.retry_jitter?.should be_true
      JoobQ.config.retry_jitter = false
      ExponentialBackoff.delay_ms(3, Random.new(42)).should eq ExponentialBackoff.ceiling_ms(3)
    end

    it "schedules a failing job within the ceiling and keeps the lock TTL on the ceiling" do
      store = JoobQ.store.as(RedisStore)
      queue = JoobQ.queues["example"]
      attempt = 4
      ceiling = ExponentialBackoff.ceiling_ms(attempt)
      job = RetryTestJob.new(1)
      store.redis.lpush("joobq:v1:processing:example", job.to_json)

      before = Time.utc.to_unix_ms
      success, _ = ExponentialBackoff.retry_idempotent(job, queue, attempt)
      after = Time.utc.to_unix_ms
      success.should be_true

      entry = store.redis.zrangebyscore(RedisStore::DELAYED_SET, "-inf", "+inf", with_scores: true)
      entry.size.should eq 2
      score = entry[1].as(String).to_f.to_i64
      score.should be >= before + ExponentialBackoff::MIN_DELAY_MS - 5
      score.should be <= after + ceiling + 5

      store.redis.ttl("joobq:v1:retry_lock:#{job.jid}").should be >= ceiling // 1000
    end
  end
end
