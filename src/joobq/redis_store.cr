module JoobQ
  class RedisStore < Store
    @@expiration = JoobQ.config.expires
    getter redis : Redis::PooledClient

    def initialize(host = ENV.fetch("REDIS_HOST", "localhost"),
                   port = ENV.fetch("REDIS_PORT", "6379").to_i,
                   password = ENV["REDIS_PASS"]?,
                   pool_size = ENV.fetch("REDIS_POOL_SIZE", "50").to_i,
                   pool_timeout = ENV.fetch("REDIS_TIMEOUT", "0.2").to_i.seconds)
      @redis = Redis::PooledClient.new(
        host: host,
        port: port,
        password: password,
        pool_size: pool_size,
        pool_timeout: pool_timeout
      )
    end

    def reset : Nil
      redis.flushdb
    end

    def add(job) : String
      redis.rpush job.queue, job.to_json
      Log.info { "Pushed - Job #{job.jid}" }
      job.jid
    end

    def push(job) : String
      config.redis.pipelined do |p|
        p.setex "jobs:#{job.jid}", job.expires || @@expiration, job.to_json
        p.rpush job.queue, "#{job.jid}"
      end
      job.jid
    end

    def find(job_id : String | UUIDi, klass : Class)
      get job_id, klass
    end

    def get(job_id : String | UUID, klass : Class)
      if job_data = redis.get("jobs:#{job_id}")
        return klass.from_json job_data.as(String)
      end
    rescue ex
      nil
    end

    def get(queue_name, klass : Class)
      if job_data = redis.brpoplpush(queue_name, Status::Busy.to_s, TIMEOUT)
        job = klass.from_json job_data.as(String)
        return job
      end
    rescue ex
      Log.error { ex.message }
      nil
    end

    def del(key)
      redis.del key

      Status.each do |status|
        redis.del status.to_s
      end
    end

    def done(job, duration)
      redis.pipelined do |pipe|
        pipe.command ["TS.ADD", "stats:processing", "*", "#{duration}", "ON_DUPLICATE", "FIRST"]
        pipe.command ["TS.ADD", "stats:#{job.queue}:success", "*", "#{duration}", "ON_DUPLICATE", "FIRST"]
      end
    end

    def failed(job, duration)
      redis.pipelined do |pipe|
        pipe.command ["TS.ADD", "stats:#{job.queue}:error", "*", "#{duration}", "ON_DUPLICATE", "FIRST"]
        pipe.zadd key, now.to_unix_f, error.to_json
        pipe.zremrangebyscore key, "-inf", expires
        pipe.zremrangebyrank key, 0, -10_000
      end
    end

    def dead(job, expires)
      redis.pipelined do |p|
        p.zadd DEAD_LETTER, now, job.jid.to_s
        p.zremrangebyscore DEAD_LETTER, "-inf", expires
        p.zremrangebyrank DEAD_LETTER, 0, -10_000
      end
    end

    def add_delayed(job : JoobQ::Job, for till : Time::Span)
      redis.zadd(Sets::Delayed.to_s, till.from_now.to_unix_f, job.to_json)
    end

    def get_delayed(now)
      moment = "%.6f" % now.to_unix_f
      redis.zrangebyscore(Sets::Delayed.to_s, "-inf", moment, limit: [0, 10])
    end

    def remove_delayed(job, queue)
      if redis.zrem(Sets::Delayed.to_s, _data)
        queue.push _data
      end
    end

    def success(job, start)
      pipe.command ["TS.ADD", "stats:#{job.queue}:success", "*", "#{latency(start)}", "ON_DUPLICATE", "FIRST"]
    end

    def processed(job, start)
      pipe.command ["TS.ADD", "stats:processing", "*", "#{latency(start)}", "ON_DUPLICATE", "FIRST"]
    end

    def failure(job, start, ex)
      key = "#{Sets::Failed.to_s}:#{job.jid}"

      REDIS.pipelined do |pipe|
        pipe.command ["TS.ADD", "stats:#{job.queue}:error", "*", "#{latency(start)}", "ON_DUPLICATE", "FIRST"]
        pipe.setex "jobs:#{job.jid}", job.expires, job.to_json

        # Add the error to the failed set
        # Remove any errors older than the expiration
        # Remove any errors beyond the 10,000th
        pipe.zadd key, now.to_unix_f, error.to_json
        pipe.zremrangebyscore key, "-inf", expires
        pipe.zremrangebyrank key, 0, -10_000
      end
    end

    private def redis
      JoobQ.config.instance.redis
    end

    private def latency(start)
      (Time.monotonic - start).milliseconds
    end
  end
end
