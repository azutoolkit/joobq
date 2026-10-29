require "./spec_helper"

module JoobQ
  describe "Redis transport boundaries" do
    it "does not replay a mutation when its response is lost" do
      listener = TCPServer.new("127.0.0.1", 0)
      calls = Atomic(Int32).new(0)
      done = Channel(Nil).new(1)
      spawn do
        while socket = listener.accept?
          begin
            request = Bytes.new(1024)
            socket.read(request)
            calls.add(1)
            # Simulate a committed command whose response is lost.
          ensure
            socket.close
          end
        end
      ensure
        done.send(nil)
      end
      store = RedisStore.new(host: "127.0.0.1", port: listener.local_address.port, pool_size: 1)
      expect_raises(RedisOutcomeUnknown) { store.redis.incr("counter") }
      calls.get.should eq(1)
    ensure
      store.try(&.close)
      listener.try(&.close)
      if done
        select
        when done.receive
        when timeout(2.seconds)
          fail "mock Redis did not stop"
        end
      end
    end

    it "enforces command timeouts on URL and TLS clients and recovers on the next request" do
      tls = ENV["JOOBQ_SPEC_TLS_REDIS_URL"]? || raise "TLS fixture required"
      ca = ENV["JOOBQ_SPEC_TLS_CA_FILE"]? || raise "TLS CA fixture required"
      plain = "redis://#{ENV.fetch("REDIS_HOST")}:#{ENV.fetch("REDIS_PORT")}"
      [plain, tls].each do |url|
        store = RedisStore.new(url: url, ca_file: ca, command_timeout: 30.milliseconds, pool_size: 1)
        begin
          store.redis.ping.should eq("PONG")
          store.redis.command(["CLIENT", "PAUSE", "150", "ALL"])
          started = Time.instant
          expect_raises(RedisOutcomeUnknown) { store.redis.ping }
          (Time.instant - started).should be < 1.second
          sleep 250.milliseconds
          store.redis.ping.should eq("PONG")
        ensure
          store.close
        end
      end
    end

    it "protects legacy client credentials and rejects invalid pool settings" do
      store = RedisStore.new(password: "never-print-this")
      store.redis.inspect.should_not contain("never-print-this")
      expect_raises(ArgumentError) { RedisStore.new(pool_size: 0) }
      expect_raises(ArgumentError) { RedisStore.new(pool_timeout: Float64::NAN) }
      expect_raises(ArgumentError) { RedisStore.new(url: "redis://localhost", command_timeout: Time::Span.zero) }
    end
  end
end
