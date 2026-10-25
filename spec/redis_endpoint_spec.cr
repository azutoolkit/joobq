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

      it "keeps a literal + in the user name and password and decodes percent escapes" do
        endpoint = RedisEndpoint.parse("redis://a+b:pa+ss%2Bword@localhost")

        endpoint.user.should eq("a+b")
        endpoint.password.should eq("pa+ss+word")
      end

      it "unwraps an IPv6 literal for connecting and wraps it again for display" do
        endpoint = RedisEndpoint.parse("rediss://[::1]:6380")

        endpoint.host.should eq("::1")
        endpoint.port.should eq(6380)
        endpoint.to_s.should contain("[::1]:6380")
      end

      it "refuses an IPv6 zone id, which cannot be connected to or verified" do
        expect_raises(RedisEndpoint::Invalid, /zone/) { RedisEndpoint.parse("rediss://[fe80::1%25eth0]:6380") }
      end

      it "asks for percent-encoding when the password contains a raw @" do
        error = expect_raises(RedisEndpoint::Invalid, /percent-encode/) { RedisEndpoint.parse("redis://u:p@ss@localhost") }

        error.message.to_s.should_not contain("p@ss")
        RedisEndpoint.parse("redis://u:p%40ss@localhost").password.should eq("p@ss")
      end

      it "rejects a query or fragment so a misplaced credential is not ignored" do
        expect_raises(RedisEndpoint::Invalid, /query/) { RedisEndpoint.parse("redis://localhost/0?password=x") }
        expect_raises(RedisEndpoint::Invalid, /fragment/) { RedisEndpoint.parse("redis://localhost/0#x") }
      end

      it "reads a unix socket path and its database" do
        endpoint = RedisEndpoint.parse("unix:///var/run/redis.sock?db=2")

        endpoint.unixsocket.should eq("/var/run/redis.sock")
        endpoint.database.should eq(2)
        endpoint.tls?.should be_false
        endpoint.ssl_context.should be_nil
        endpoint.to_s.should contain("/var/run/redis.sock")
      end

      it "rejects a unix URL without a path or with other parameters" do
        expect_raises(RedisEndpoint::Invalid, /socket/) { RedisEndpoint.parse("unix://") }
        expect_raises(RedisEndpoint::Invalid, /parameter/) { RedisEndpoint.parse("unix:///tmp/r.sock?password=x") }
        expect_raises(RedisEndpoint::Invalid, /database/) { RedisEndpoint.parse("unix:///tmp/r.sock?db=x") }
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

      it "fails closed instead of skipping the host name check for a host that is only a dot" do
        endpoint = RedisEndpoint.parse("rediss://.")

        expect_raises(RedisEndpoint::Invalid, /host/) { endpoint.ssl_context }
      end

      it "rejects a CA file that cannot be read" do
        endpoint = RedisEndpoint.parse("rediss://localhost", ca_file: "/nonexistent/ca.pem")

        expect_raises(RedisEndpoint::Invalid, /CA file/) { endpoint.ssl_context }
      end
    end
  end
end
