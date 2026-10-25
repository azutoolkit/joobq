module JoobQ
  # A `Redis` that knows ACL users and TLS endpoints. The shard sends `AUTH password`, which authenticates the default
  # user only; with a user name this sends `AUTH user password` each time it (re)connects, then selects the database.
  class RedisClient < Redis
    def initialize(endpoint : RedisEndpoint, connect_timeout : Time::Span? = 5.seconds, command_timeout : Time::Span? = nil)
      @acl_user = endpoint.user
      @acl_password = endpoint.password
      @acl_database = endpoint.database
      if endpoint.user
        super(host: endpoint.host, port: endpoint.port, password: nil, database: nil,
          ssl_context: endpoint.ssl_context, connect_timeout: connect_timeout, command_timeout: command_timeout)
      else
        super(host: endpoint.host, port: endpoint.port, password: endpoint.password, database: endpoint.database,
          ssl_context: endpoint.ssl_context, connect_timeout: connect_timeout, command_timeout: command_timeout)
      end
    end

    private def connect
      super
      if user = @acl_user
        strategy.command(["AUTH", user, @acl_password.to_s])
        @acl_database.try { |db| strategy.command(["SELECT", db.to_s]) }
      end
    end
  end

  # `Redis::PooledClient` whose connections are `RedisClient`s.
  class RedisPool < Redis::PooledClient
    def initialize(endpoint : RedisEndpoint, pool_size : Int32 = 5, pool_timeout : Float64 = 5.0)
      @pool = ConnectionPool(Redis).new(capacity: pool_size, timeout: pool_timeout) { RedisClient.new(endpoint).as(Redis) }
    end
  end
end
