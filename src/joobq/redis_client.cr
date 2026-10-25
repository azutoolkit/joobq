module JoobQ
  # A `Redis` that knows ACL users and TLS endpoints. The shard sends `AUTH password`, which authenticates the default
  # user only; here the client sends `AUTH user password` (or `AUTH password`) itself on every (re)connect and then
  # selects the database. If either step fails the connection is closed before the error is raised, so the next
  # command reconnects and authenticates again instead of running on a connection that never did: as the default
  # user, which is often `nopass` with every right, and on database 0.
  class RedisClient < Redis
    def initialize(endpoint : RedisEndpoint, connect_timeout : Time::Span? = 5.seconds, command_timeout : Time::Span? = nil,
                   ssl_context : OpenSSL::SSL::Context::Client? = endpoint.ssl_context)
      @acl_user = endpoint.user
      @acl_password = endpoint.password
      @acl_database = endpoint.database
      super(host: endpoint.host, port: endpoint.port, unixsocket: endpoint.unixsocket, password: nil, database: nil,
        ssl_context: ssl_context, connect_timeout: connect_timeout, command_timeout: command_timeout)
    end

    private def connect
      super
      begin
        if user = @acl_user
          strategy.command(["AUTH", user, @acl_password.to_s])
        elsif password = @acl_password
          strategy.command(["AUTH", password])
        end
        @acl_database.try { |db| strategy.command(["SELECT", db.to_s]) }
      rescue ex
        close
        raise ex
      end
    end

    # The credentials stay out of `inspect`, `pp` and exception dumps.
    def inspect(io : IO) : Nil
      io << "#<" << self.class.name << ' ' << @host << ':' << @port << '>'
    end
  end

  # `Redis::PooledClient` whose connections are `RedisClient`s. The TLS context is built once and shared.
  class RedisPool < Redis::PooledClient
    def initialize(endpoint : RedisEndpoint, pool_size : Int32 = 5, pool_timeout : Float64 = 5.0)
      ssl_context = endpoint.ssl_context
      @clients = [] of RedisClient
      @clients_lock = Sync::Mutex.new
      @pool = ConnectionPool(Redis).new(capacity: pool_size, timeout: pool_timeout) do
        client = RedisClient.new(endpoint, ssl_context: ssl_context)
        @clients_lock.synchronize { @clients << client }
        client.as(Redis)
      end
      @description = endpoint.to_s
    end

    # Closes every connection the pool has opened. A command issued afterwards reconnects, so this is for letting go of
    # a server (an environment that is removed, a process that is ending), not for pausing.
    def close : Nil
      clients = @clients_lock.synchronize { @clients.dup }
      clients.each(&.close)
    end

    def inspect(io : IO) : Nil
      io << "#<" << self.class.name << ' ' << @description << '>'
    end
  end
end
