module JoobQ
  class Configure
    INSTANCE = new

    getter redis : Redis::PooledClient = Redis::PooledClient.new(
      host: ENV.fetch("REDIS_HOST", "localhost"),
      port: ENV.fetch("REDIS_PORT", "6379").to_i,
      pool_size: ENV.fetch("REDIS_POOL_SIZE", "50").to_i,
      pool_timeout: ENV.fetch("REDIS_TIMEOUT", "0.2").to_f
    )

    getter queues = {} of String => BaseQueue

    macro queue(name, workers, kind)
      {% begin %}
      queues[{{name}}] = JoobQ::Queue({{kind.id}}).new({{name}}, {{workers}})
      {% end %}
    end

    def scheduler
      with Scheduler.instance yield
    end
  end
end
