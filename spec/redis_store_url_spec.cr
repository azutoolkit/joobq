require "./spec_helper"

module JoobQ
  # RedisStore.new(url:) connects as an ACL user (AUTH user password), which the redis shard cannot do by itself.
  # The spec creates a restricted user on the test Redis and removes it again.
  describe "RedisStore.new(url:)" do
    host = ENV["REDIS_HOST"]? || "localhost"
    port = ENV.fetch("REDIS_PORT", "6379").to_i
    user = "joobq_spec_acl"
    secret = "s3cr3t-for-spec"
    url = "redis://#{user}:#{secret}@#{host}:#{port}"

    admin = -> { Redis.new(host: host, port: port) }

    before_each do
      begin
        admin.call.command(["ACL", "SETUSER", user, "on", ">#{secret}", "~acl_spec:*", "+@all", "-@dangerous"])
      rescue Redis::Error
        pending!("needs Redis 6+ with ACL support")
      end
    end

    after_each do
      begin
        admin.call.command(["ACL", "DELUSER", user])
      rescue Redis::Error
      end
    end

    it "authenticates as the ACL user and can use the keys it is allowed" do
      store = RedisStore.new(url: url)

      store.redis.set("acl_spec:key", "value")
      store.redis.get("acl_spec:key").should eq("value")
    ensure
      admin.call.del("acl_spec:key")
    end

    it "is held to the user's ACL: other keys and dangerous commands are refused" do
      store = RedisStore.new(url: url)

      expect_raises(Redis::Error, /NOPERM/) { store.redis.set("other:key", "value") }
      expect_raises(Redis::Error, /NOPERM/) { store.redis.flushdb }
    end

    it "fails on a wrong password without repeating it" do
      store = RedisStore.new(url: "redis://#{user}:not-the-password@#{host}:#{port}")

      error = expect_raises(Redis::Error) { store.redis.get("acl_spec:key") }

      error.message.to_s.should_not contain("not-the-password")
    end

    it "keeps failing after a failed AUTH instead of falling back to the default user" do
      # One pooled connection is reused, so a half-open connection would run the second command as the default user.
      store = RedisStore.new(url: "redis://#{user}:not-the-password@#{host}:#{port}", pool_size: 1)

      2.times { expect_raises(Redis::Error) { store.redis.get("acl_spec:key") } }
    end

    it "does not fall back to the default user when AUTH fails on a reconnect" do
      store = RedisStore.new(url: url, pool_size: 1)
      store.redis.set("acl_spec:key", "value") # one connection, authenticated as the ACL user

      # The password is rotated and the live connection dropped, so the next command has to reconnect and AUTH again.
      admin_client = admin.call
      admin_client.command(["ACL", "SETUSER", user, "resetpass", ">rotated-password"])
      admin_client.command(["CLIENT", "KILL", "USER", user])

      3.times { expect_raises(Redis::Error) { store.redis.get("acl_spec:key") } }
    ensure
      admin.call.del("acl_spec:key")
    end

    it "does not print the password when the store or its pool is inspected" do
      store = RedisStore.new(url: url, pool_size: 1)
      store.redis.set("acl_spec:key", "value")

      [store.inspect, store.redis.inspect, store.pretty_inspect, store.redis.pretty_inspect].each do |text|
        text.should_not contain(secret)
      end
    ensure
      admin.call.del("acl_spec:key")
    end

    it "selects the database from the URL" do
      store = RedisStore.new(url: "#{url}/5")

      store.redis.set("acl_spec:db", "five")

      other = admin.call
      other.select(5)
      other.get("acl_spec:db").should eq("five")
    ensure
      cleanup = admin.call
      cleanup.select(5)
      cleanup.del("acl_spec:db")
    end

    it "fails at construction, not at the first command, when the CA file cannot be read" do
      expect_raises(RedisEndpoint::Invalid, /CA file/) do
        RedisStore.new(url: "rediss://#{host}:#{port}", ca_file: "/nonexistent/ca.pem")
      end
    end

    it "leaves the host, port and password constructor working" do
      store = RedisStore.new(host: host, port: port, password: nil, pool_size: 2, pool_timeout: 1.0)

      store.redis.ping.should eq("PONG")
    end
  end
end
