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

    stores = [] of RedisStore
    connect = ->(target : String, pool_size : Int32) { RedisStore.new(url: target, pool_size: pool_size).tap { |store| stores << store } }
    admins = [] of Redis
    admin = -> { admins.first? || Redis.new(host: host, port: port).tap { |client| admins << client } }

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
      stores.each(&.close)
      stores.clear
      admins.each(&.close)
      admins.clear
    end

    it "authenticates as the ACL user and can use the keys it is allowed" do
      store = connect.call(url, 2)

      store.redis.set("acl_spec:key", "value")
      store.redis.get("acl_spec:key").should eq("value")
    ensure
      admin.call.del("acl_spec:key")
    end

    it "is held to the user's ACL: other keys and dangerous commands are refused" do
      store = connect.call(url, 2)

      expect_raises(Redis::Error, /NOPERM/) { store.redis.set("other:key", "value") }
      expect_raises(Redis::Error, /NOPERM/) { store.redis.flushdb }
    end

    it "fails on a wrong password without repeating it" do
      store = connect.call("redis://#{user}:not-the-password@#{host}:#{port}", 2)

      error = expect_raises(Redis::Error) { store.redis.get("acl_spec:key") }

      error.message.to_s.should_not contain("not-the-password")
    end

    it "reports the authentication failure on every attempt, not a pool timeout after the first" do
      # A client whose AUTH fails must still take its place in the pool, or each failure would use up one slot of a
      # one-connection pool and the second attempt would time out waiting for a connection that never comes back.
      store = connect.call("redis://#{user}:not-the-password@#{host}:#{port}", 1)

      3.times { expect_raises(Redis::Error, /WRONGPASS/) { store.redis.get("acl_spec:key") } }
    end

    it "does not fall back to the default user when AUTH fails on a reconnect" do
      store = connect.call(url, 1)
      store.redis.set("acl_spec:key", "value") # one connection, authenticated as the ACL user

      # The password is rotated and the live connection dropped, so the next command has to reconnect and AUTH again.
      admin.call.command(["ACL", "SETUSER", user, "resetpass", ">rotated-password"])
      admin.call.command(["CLIENT", "KILL", "USER", user])

      3.times { expect_raises(Redis::Error) { store.redis.get("acl_spec:key") } }
    ensure
      admin.call.del("acl_spec:key")
    end

    it "does not print the password when the store or its pool is inspected" do
      store = connect.call(url, 1)
      store.redis.set("acl_spec:key", "value")

      [store.inspect, store.redis.inspect, store.pretty_inspect, store.redis.pretty_inspect].each do |text|
        text.should_not contain(secret)
      end
    ensure
      admin.call.del("acl_spec:key")
    end

    it "selects the database from the URL" do
      store = connect.call("#{url}/5", 2)

      store.redis.set("acl_spec:db", "five")

      db_client = Redis.new(host: host, port: port, database: 5)
      db_client.get("acl_spec:db").should eq("five")
    ensure
      cleanup = Redis.new(host: host, port: port, database: 5)
      cleanup.del("acl_spec:db")
      cleanup.close
      db_client.try(&.close)
    end

    it "fails at construction, not at the first command, when the CA file cannot be read" do
      expect_raises(RedisEndpoint::Invalid, /CA file/) do
        RedisStore.new(url: "rediss://#{host}:#{port}", ca_file: "/nonexistent/ca.pem")
      end
    end

    it "closes its connections on #close" do
      store = connect.call(url, 2)
      store.redis.set("acl_spec:key", "value")
      admin.call.command(["CLIENT", "LIST"]).to_s.should contain("user=#{user}")

      store.close

      admin.call.command(["CLIENT", "LIST"]).to_s.should_not contain("user=#{user}")
    ensure
      admin.call.del("acl_spec:key")
    end

    it "leaves the host, port and password constructor working" do
      store = RedisStore.new(host: host, port: port, password: nil, pool_size: 2, pool_timeout: 1.0)

      store.redis.ping.should eq("PONG")
    end
  end
end
