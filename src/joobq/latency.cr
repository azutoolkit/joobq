module JoobQ
  # How long jobs take to run, as a histogram every process adds to and any process can read.
  #
  # Each execution lands in one of a fixed set of logarithmic buckets (eight per decade, 1 ms to about 12 minutes,
  # then one for anything slower). Workers keep counts in memory and add them to the cumulative hash
  # `joobq:stats:latency` ("queue|bucket" => count) every few seconds, like the other `joobq:stats:*` counters.
  # A reader that samples the hash twice has the distribution of what ran in between, and merges
  # distributions by adding buckets.
  #
  # A bucket is 33 % wider than the one below it, so a percentile reported as the middle of its bucket is
  # off by at most about 15 % between 1 ms and about 12 minutes; jobs faster than 1 ms report as 1 ms and
  # slower ones as the last bound. Delivery to Redis is at least once: counts handed back after a failed flush
  # may include some the server had already applied.
  module Latency
    Log = ::Log.for("LATENCY")

    KEY           = "joobq:stats:latency"
    FLUSH_EVERY   = 5.seconds
    FIRST_SECONDS = 0.001
    PER_DECADE    =     8
    LAST_BUCKET   =    47 # 749 s
    OVERFLOW      = LAST_BUCKET + 1
    BUCKET_COUNT  = OVERFLOW + 1

    @@lock = Sync::Mutex.new
    @@counts = {} of String => Array(Int64)
    @@loop = BackgroundLoop.new("latency_flush")

    # The bucket a duration falls in: the first whose upper bound is at least the duration.
    def self.bucket(seconds : Float64) : Int32
      return 0 if seconds <= FIRST_SECONDS

      Math.min((Math.log10(seconds / FIRST_SECONDS) * PER_DECADE).ceil.to_i, OVERFLOW)
    end

    # The upper bound of a bucket in seconds; the overflow bucket reports the last bound.
    def self.upper_seconds(bucket : Int32) : Float64
      FIRST_SECONDS * 10.0 ** (Math.min(bucket, LAST_BUCKET) / PER_DECADE.to_f)
    end

    # The geometric middle of a bucket, in seconds: the best single value to report for it.
    def self.middle_seconds(bucket : Int32) : Float64
      return upper_seconds(bucket) if bucket <= 0 || bucket > LAST_BUCKET

      Math.sqrt(upper_seconds(bucket - 1) * upper_seconds(bucket))
    end

    # Counts one execution. Cheap enough for every job: a lookup and an add under a lock held for nanoseconds.
    def self.observe(queue : String, seconds : Float64) : Nil
      add(queue, bucket(seconds), 1_i64)
      start_flushing
    end

    # Adds what this process has counted since the last flush to the shared hash. When Redis cannot be
    # reached the counts are kept for the next try.
    def self.flush(redis : Redis::PooledClient = RedisStore.instance.redis) : Nil
      taken = take
      return if taken.empty?

      redis.pipelined { |pipe| taken.each { |(field, count)| pipe.hincrby(KEY, field, count) } }
    rescue ex
      taken.try(&.each { |(field, count)| give_back(field, count) })
      raise ex
    end

    # Reads the shared hash: queue => counts per bucket.
    def self.read(redis : Redis::PooledClient = RedisStore.instance.redis) : Hash(String, Array(Int64))
      totals = {} of String => Array(Int64)
      redis.hgetall(KEY).each do |field, count|
        queue, _, bucket = field.to_s.rpartition('|')
        index = bucket.to_i? || next
        next unless 0 <= index < BUCKET_COUNT

        (totals[queue] ||= Array(Int64).new(BUCKET_COUNT, 0_i64))[index] = count.to_s.to_i64
      end
      totals
    end

    # Stops publishing in the background and publishes what is left. Counting again restarts it.
    def self.stop : Nil
      @@loop.stop
      publish_now
    end

    # Publishes what is left, without failing the caller: shutdown must not depend on Redis being up.
    def self.publish_now : Nil
      flush
    rescue ex
      Log.warn &.emit("Could not publish job latencies", error: ex.message)
    end

    # Forgets what this process has counted; for specs.
    def self.reset : Nil
      @@lock.synchronize { @@counts.clear }
    end

    private def self.add(queue : String, bucket : Int32, count : Int64) : Nil
      @@lock.synchronize { (@@counts[queue] ||= Array.new(BUCKET_COUNT, 0_i64))[bucket] += count }
    end

    private def self.take : Array({String, Int64})
      taken = [] of {String, Int64}
      @@lock.synchronize do
        @@counts.each do |queue, counts|
          counts.each_with_index do |count, bucket|
            next if count == 0

            taken << {"#{queue}|#{bucket}", count}
            counts[bucket] = 0_i64
          end
        end
      end
      taken
    end

    private def self.give_back(field : String, count : Int64) : Nil
      queue, _, bucket = field.rpartition('|')
      add(queue, bucket.to_i, count)
    end

    # A process that records latencies also publishes them, without having to be told to.
    private def self.start_flushing : Nil
      return if @@loop.running?

      first = true
      @@loop.start do
        if first # the loop runs its body at once; give the process time to count something
          first = false
          next FLUSH_EVERY
        end

        flush
        FLUSH_EVERY
      rescue ex
        Log.warn &.emit("Could not publish job latencies", error: ex.message)
        FLUSH_EVERY
      end
    end
  end
end
