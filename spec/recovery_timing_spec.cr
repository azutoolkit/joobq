require "./spec_helper"

module JoobQ
  describe "crash recovery timing" do
    store = JoobQ.store.as(RedisStore)
    redis = store.redis
    name = "example"
    crashed = "crashed-host:7001"

    after_each do
      store.owner_ttl = RedisStore::DEFAULT_OWNER_TTL
      JoobQ.config.reaper_interval = 30.seconds
      redis.del(Keys.queue(name), Keys.processing(name, crashed))
      redis.zrem(RedisStore::OWNERS, crashed)
    end

    describe "defaults" do
      it "keep the 30 s owner TTL, the 30 s reaper interval and a 10 s heartbeat" do
        store.owner_ttl.should eq(30.seconds)
        store.owner_beat.should eq(10.seconds)
        Configure.new.owner_ttl.should eq(30.seconds)
        Configure.new.reaper_interval.should eq(30.seconds)
      end
    end

    describe "a short TTL" do
      it "lapses a heartbeat sooner and beats at a third of the TTL" do
        store.owner_ttl = 3.seconds
        store.owner_beat.should eq(1.second)
        redis.zadd(RedisStore::OWNERS, store.redis_now_ms - 4_000, crashed)
        store.live_owners.includes?(crashed).should be_false
      end

      it "returns a SIGKILLed owner's jobs inside TTL + reaper interval" do
        store.owner_ttl = 1.second
        interval = 500.milliseconds
        claimed = ["A", "B", "C"]
        claimed.reverse_each { |job| redis.lpush(Keys.processing(name, crashed), job) }
        redis.zadd(RedisStore::OWNERS, store.redis_now_ms, crashed) # its last beat, just now

        reaper = ExpiredJobReaper.new(store: store, interval: interval)
        started = Time.instant
        reaper.start
        begin
          eventually(5.seconds) { redis.llen(Keys.queue(name)) == 3 }.should be_true
          elapsed = Time.instant - started
          elapsed.should be <= (store.owner_ttl + interval + 1.second)
          redis.lrange(Keys.queue(name), 0, -1).map(&.as(String)).sort.should eq(claimed)
          redis.exists(Keys.processing(name, crashed)).should eq(0)
        ensure
          reaper.stop
        end
      end
    end

    describe "validation" do
      it "refuses an owner TTL outside 1 second to 1 hour" do
        expect_raises(ConfigValidationError, /owner_ttl/) { store.owner_ttl = 500.milliseconds }
        expect_raises(ConfigValidationError, /owner_ttl/) { store.owner_ttl = 2.hours }
        expect_raises(ConfigValidationError, /owner_ttl/) { JoobQ::Configure.new.owner_ttl = 0.seconds }
      end

      it "refuses a reaper interval longer than the owner TTL" do
        config = Configure.new
        config.owner_ttl = 5.seconds
        config.reaper_interval = 6.seconds
        expect_raises(ConfigValidationError, /reaper_interval.*owner_ttl/) { config.validate_configuration }
        config.reaper_interval = 5.seconds
        config.validate_configuration
      end

      it "refuses a reaper interval under 100 ms" do
        config = Configure.new
        config.reaper_interval = 50.milliseconds
        expect_raises(ConfigValidationError, /reaper_interval/) { config.validate_configuration }
      end

      it "passes the setting to the store of the configuration" do
        config = Configure.new
        config.owner_ttl = 7.seconds
        config.store.as(RedisStore).owner_ttl.should eq(7.seconds)
        replacement = RedisStore.new
        config.store = replacement
        replacement.owner_ttl.should eq(7.seconds)
      end
    end

    describe "YAML" do
      it "reads owner_ttl and reaper_interval from settings" do
        yaml = <<-YAML
          joobq:
            settings:
              owner_ttl: "10 seconds"
              reaper_interval: "5 seconds"
          YAML
        config = YamlConfigLoader.load_from_string(yaml)
        config.owner_ttl.should eq(10.seconds)
        config.reaper_interval.should eq(5.seconds)
      end

      it "refuses an interval above the TTL" do
        yaml = <<-YAML
          joobq:
            settings:
              owner_ttl: "10 seconds"
              reaper_interval: "20 seconds"
          YAML
        expect_raises(ConfigLoadError, /reaper_interval/) { YamlConfigLoader.load_from_string(yaml) }
      end

      it "reads JOOBQ_OWNER_TTL and JOOBQ_REAPER_INTERVAL from the environment overrides" do
        ENV["JOOBQ_OWNER_TTL"] = "12 seconds"
        ENV["JOOBQ_REAPER_INTERVAL"] = "4 seconds"
        config = YamlConfigLoader.load_with_env_overrides(File.expand_path("../config/joobq.base.yml", __DIR__))
        config.owner_ttl.should eq(12.seconds)
        config.reaper_interval.should eq(4.seconds)

        ENV["JOOBQ_REAPER_INTERVAL"] = "20 seconds"
        expect_raises(ConfigValidationError, /reaper_interval/) do
          YamlConfigLoader.load_with_env_overrides(File.expand_path("../config/joobq.base.yml", __DIR__))
        end
      ensure
        ENV.delete("JOOBQ_OWNER_TTL")
        ENV.delete("JOOBQ_REAPER_INTERVAL")
      end

      it "refuses a TTL that is not a time span" do
        yaml = <<-YAML
          joobq:
            settings:
              owner_ttl: "soon"
          YAML
        expect_raises(ConfigLoadError, /owner_ttl|time span/i) { YamlConfigLoader.load_from_string(yaml) }
      end
    end
  end
end
