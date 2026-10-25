require "./spec_helper"

module JoobQ
  describe RedisEndpoint do
    describe ".parse" do
      it "reads host, port, user, password, database and TLS from a rediss URL" do
        endpoint = RedisEndpoint.parse("rediss://svc:p%40ss%3Aword@redis.example.com:6380/3")

        endpoint.host.should eq("redis.example.com")
        endpoint.port.should eq(6380)
        endpoint.user.should eq("svc")
        endpoint.password.should eq("p@ss:word")
        endpoint.database.should eq(3)
        endpoint.tls?.should be_true
      end

      it "defaults to port 6379, no credentials, no database and no TLS for a bare redis URL" do
        endpoint = RedisEndpoint.parse("redis://localhost")

        endpoint.port.should eq(6379)
        endpoint.user.should be_nil
        endpoint.password.should be_nil
        endpoint.database.should be_nil
        endpoint.tls?.should be_false
      end

      it "treats a password without a user name as the default user's password" do
        endpoint = RedisEndpoint.parse("redis://:secret@localhost")

        endpoint.user.should be_nil
        endpoint.password.should eq("secret")
      end

      it "rejects a scheme other than redis and rediss" do
        expect_raises(RedisEndpoint::Invalid, /scheme/) { RedisEndpoint.parse("http://localhost") }
      end

      it "rejects a URL without a host" do
        expect_raises(RedisEndpoint::Invalid, /host/) { RedisEndpoint.parse("redis:///0") }
      end

      it "rejects a database that is not a whole number" do
        expect_raises(RedisEndpoint::Invalid, /database/) { RedisEndpoint.parse("redis://localhost/main") }
      end

      it "rejects a malformed URL without echoing it" do
        error = expect_raises(RedisEndpoint::Invalid) { RedisEndpoint.parse("redis://svc:hunter2@local host:port") }

        error.message.to_s.should_not contain("hunter2")
      end
    end

    describe "#to_s and #inspect" do
      it "never contain the password or the URL's credentials" do
        endpoint = RedisEndpoint.parse("rediss://svc:hunter2@redis.example.com:6380/3")

        [endpoint.to_s, endpoint.inspect].each do |text|
          text.should contain("redis.example.com:6380")
          text.should_not contain("hunter2")
        end
      end
    end

    describe "#ssl_context" do
      ca_file = File.expand_path("fixtures/tls/ca.pem", __DIR__)

      it "is nil for a plain connection" do
        RedisEndpoint.parse("redis://localhost").ssl_context.should be_nil
      end

      it "verifies the server certificate by default and refuses the old protocols" do
        context = RedisEndpoint.parse("rediss://localhost").ssl_context.not_nil!

        context.verify_mode.should eq(OpenSSL::SSL::VerifyMode::PEER)
        options = context.options
        [LibSSL::Options::NO_SSL_V3, LibSSL::Options::NO_TLS_V1, LibSSL::Options::NO_TLS_V1_1].each do |flag|
          options.includes?(flag).should be_true
        end
      end

      it "turns verification off only when asked to" do
        context = RedisEndpoint.parse("rediss://localhost", verify: false).ssl_context.not_nil!

        context.verify_mode.should eq(OpenSSL::SSL::VerifyMode::NONE)
      end

      it "trusts the given CA file" do
        endpoint = RedisEndpoint.parse("rediss://localhost", ca_file: ca_file)

        endpoint.ssl_context.should_not be_nil
      end

      it "rejects a CA file that cannot be read" do
        endpoint = RedisEndpoint.parse("rediss://localhost", ca_file: "/nonexistent/ca.pem")

        expect_raises(RedisEndpoint::Invalid, /CA file/) { endpoint.ssl_context }
      end
    end
  end
end
