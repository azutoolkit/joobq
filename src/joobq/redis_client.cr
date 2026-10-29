module JoobQ
  # A `Redis` that knows ACL users and TLS endpoints. The shard sends `AUTH password`, which authenticates the default
  # user only; here the client sends `AUTH user password` (or `AUTH password`) itself on every (re)connect and then
  # selects the database. If either step fails the connection is closed before the error is raised, so the next
  # command reconnects and authenticates again instead of running on a connection that never did: as the default
  # user, which is often `nopass` with every right, and on database 0.
  # The server may have executed a command whose reply was lost. The caller must
  # resolve its request identity rather than blindly replay a mutation.
  class RedisOutcomeUnknown < Redis::ConnectionLostError
  end

  class RedisClient < Redis
    def initialize(endpoint : RedisEndpoint, connect_timeout : Time::Span? = 5.seconds, command_timeout : Time::Span? = 5.seconds,
                   ssl_context : OpenSSL::SSL::Context::Client? = endpoint.ssl_context)
      @acl_user = endpoint.user
      @acl_password = endpoint.password
      @acl_database = endpoint.database
      super(host: endpoint.host, port: endpoint.port, unixsocket: endpoint.unixsocket, password: nil, database: nil,
        ssl_context: ssl_context, dns_timeout: connect_timeout, connect_timeout: connect_timeout, command_timeout: command_timeout)
    end

    # Reconnect before a new request, but never replay a request after a lost reply.
    # The dependency's implementation retries *all* commands once, including RPUSH.
    def command(request : Redis::Request)
      transport = strategy
      begin
        transport.command(request).as(Redis::RedisValue)
      rescue ex : Redis::ConnectionError | Redis::CommandTimeoutError
        close
        raise RedisOutcomeUnknown.new("Redis reply unavailable; command outcome is unknown (#{ex.class})")
      end
    end

    # Redis errors can interrupt reply draining midway through a pipeline. Never
    # return that socket to the pool with unread replies for the next borrower.
    # A pipeline is not a transaction: any prefix may already have executed.
    def pipelined(&)
      super { |pipeline| yield pipeline }
    rescue ex : Redis::ConnectionError | Redis::CommandTimeoutError
      close
      raise RedisOutcomeUnknown.new("Redis pipeline reply unavailable; outcome is unknown (#{ex.class})")
    rescue ex
      close
      raise ex
    end

    # A block can abort with MULTI still buffered, and an EXEC element error can
    # interrupt reply draining after other mutations committed. Never flush or
    # reuse that connection, and never replay a transaction with an unknown outcome.
    def multi(&)
      super { |transaction| yield transaction }
    rescue ex : Redis::ConnectionError | Redis::CommandTimeoutError
      close
      raise RedisOutcomeUnknown.new("Redis transaction reply unavailable; outcome is unknown (#{ex.class})")
    rescue ex
      close
      raise ex
    end

    private def connect
      @connection = DeadlineConnection.new(@host, @port, @unixsocket, @ssl_context,
        @dns_timeout, @connect_timeout, @command_timeout)
      @strategy = Redis::Strategy::SingleStatement.new(@connection.not_nil!)
      begin
        if user = @acl_user
          strategy.command(["AUTH", user, @acl_password.to_s])
        elsif password = @acl_password
          strategy.command(["AUTH", password])
        end
        @acl_database.try { |db| strategy.command(["SELECT", db.to_s]) }
      rescue ex
        begin
          close
        rescue
          # closing a broken socket can fail too; the authentication error is the one to report
        ensure
          # whatever happened, the next command must reconnect and authenticate again
          @connection = nil
          @strategy = nil
        end
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
    def initialize(endpoint : RedisEndpoint, pool_size : Int32 = 5, pool_timeout : Float64 = 5.0,
                   connect_timeout : Time::Span = 5.seconds, command_timeout : Time::Span = 5.seconds,
                   @operation_timeout : Time::Span = 5.seconds)
      raise ArgumentError.new("Redis pool size and timeouts must be positive and finite") unless pool_size > 0 && pool_timeout.finite? && pool_timeout > 0 && connect_timeout > Time::Span.zero && command_timeout > Time::Span.zero
      raise ArgumentError.new("operation timeout must be positive") unless @operation_timeout > Time::Span.zero
      ssl_context = endpoint.ssl_context
      @clients = [] of RedisClient
      @clients_lock = Sync::Mutex.new
      @pool = ConnectionPool(Redis).new(capacity: pool_size, timeout: pool_timeout) do
        client = RedisClient.new(endpoint, connect_timeout: connect_timeout, command_timeout: command_timeout, ssl_context: ssl_context)
        @clients_lock.synchronize { @clients << client }
        client.as(Redis)
      end
      @description = endpoint.to_s
    end

    private def with_pool_connection(&)
      previous = Fiber.current.joobq_redis_deadline
      deadline = Time.instant + @operation_timeout
      Fiber.current.joobq_redis_deadline = previous ? Math.min(previous, deadline) : deadline
      begin
        connection = @pool.checkout
        RedisBudget.remaining
        yield connection
      rescue ex : IO::TimeoutError
        connection.try(&.close)
        raise Redis::PoolTimeoutError.new("Redis total operation deadline exceeded")
      ensure
        @pool.checkin(connection) if connection
        Fiber.current.joobq_redis_deadline = previous
      end
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
