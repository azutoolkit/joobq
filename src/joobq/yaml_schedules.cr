require "digest/sha256"

module JoobQ
  # Fires the YAML `schedulers:` entries (`Configure#scheduler_configs`): a cron or recurring entry enqueues a new job
  # of its class, built from the entry's `args`, onto the queue that serves the class each time it is due. Cron entries
  # run on a `Scheduler`'s `CronJobScheduler`, recurring ones on its `RecurringJobScheduler`, as the DSL's `cron` and
  # `every` do. `JoobQ.forge` starts them unless `Configure#fire_yaml_schedulers?` is false.
  #
  # Every process that runs them computes the same key for an entry and claims it in Redis (`SET NX PX`), so one
  # process enqueues each run however many run `forge`: a cron entry claims its minute (`Keys.schedule_tick`), a
  # recurring one the right to enqueue for about one interval (`Keys.schedule_claim`; no clock has to agree). The claim
  # comes first, so a crash between it and the enqueue loses that run; a failed enqueue gives the claim back.
  # Cron patterns have a minute's resolution: an entry fires at most once a minute.
  class YamlSchedules
    # A recurring entry may not run more often than this.
    MIN_INTERVAL = 1.second
    # How long a cron tick's claim is kept (a tick is a minute).
    CRON_CLAIM_TTL = 2.minutes

    getter config : Configure

    # Takes a claim for `ARGV[1]` (the owner) when the key is free or already the owner's, and extends it.
    CLAIM = <<-LUA
      local holder = redis.call('GET', KEYS[1])
      if holder == false or holder == ARGV[1] then
        redis.call('SET', KEYS[1], ARGV[1], 'PX', ARGV[2])
        return 1
      end
      return 0
      LUA

    # Deletes a claim only when it is still the owner's.
    RELEASE = <<-LUA
      if redis.call('GET', KEYS[1]) == ARGV[1] then
        return redis.call('DEL', KEYS[1])
      end
      return 0
      LUA

    @lock = Sync::Mutex.new
    @started : Array(Scheduler)? = nil
    # Names this instance's claims: another process's claim is refused until it expires, one's own is renewed.
    @owner = Random::Secure.hex(16)

    def initialize(@config : Configure)
    end

    # Raises `ConfigValidationError` for an entry that could not fire: an unknown time zone, an invalid cron pattern, an
    # interval under a second, a job type that is not registered, arguments the job cannot be built from, or a job
    # that no (or more than one) configured queue serves. Checks nothing when firing is off.
    def validate! : Nil
      return unless @config.fire_yaml_schedulers?

      @config.scheduler_configs.each do |group|
        zone(group[:timezone])
        group[:cron_jobs].each do |entry|
          validate_pattern(entry[:pattern])
          build(entry[:job], entry[:args])
        end
        group[:recurring_jobs].each do |entry|
          validate_interval(entry[:job], entry[:interval])
          build(entry[:job], entry[:args])
        end
      end
    end

    # Starts a scheduler per configured group and returns them. Does nothing the second time (it returns the ones
    # running) until `stop`; starts none when firing is off. Validates first, so a bad entry starts nothing.
    def start : Array(Scheduler)
      return [] of Scheduler unless @config.fire_yaml_schedulers?

      @lock.synchronize do
        next [] of Scheduler if JoobQ.shut_down?

        @started || begin
          validate!
          started = [] of Scheduler
          begin
            index = 0
            @config.scheduler_configs.each do |group|
              scheduler = Scheduler.new(time_location: zone(group[:timezone]))
              started << scheduler
              index = register(scheduler, group, index)
            end
          rescue ex
            started.each(&.stop)
            raise ex
          end
          @started = started
        end
      end
    end

    # Stops what `start` started (`JoobQ.shutdown` calls it); `start` may then run again.
    def stop : Nil
      started = @lock.synchronize { @started.tap { @started = nil } }
      started.try(&.each(&.stop))
    end

    # Builds a job of the named type from `args` and enqueues it; returns its job id.
    def enqueue(job : String, args : Hash(String, YAML::Any)) : String
      JoobQ.enqueue(build(job, args))
    end

    # Enqueues the job unless another process (or an earlier call) already claimed this cron entry's `tick`; returns its
    # job id, or nil when the tick was taken, the claim could not be made or the job could not be enqueued (logged).
    def enqueue_tick(entry : String, tick : Int64, ttl : Time::Span, job : String, args : Hash(String, YAML::Any)) : String?
      enqueue_claimed(Keys.schedule_tick(entry, tick), ttl, job, args)
    end

    # The same for a recurring entry: the claim lasts about `interval` (a little less, so a process whose loop runs a
    # little early is not refused), so the entry is enqueued about once an interval, by whichever process is first.
    def enqueue_every(entry : String, interval : Time::Span, job : String, args : Hash(String, YAML::Any)) : String?
      enqueue_claimed(Keys.schedule_claim(entry), claim_ttl(interval), job, args)
    end

    # How long a recurring entry's claim lasts: the interval less a margin of a tenth (at most 5 seconds, at least 1
    # for intervals of 4 seconds and more).
    def claim_ttl(interval : Time::Span) : Time::Span
      margin = {interval / 10, 5.seconds}.min
      margin = {margin, 1.second}.max if interval >= 4.seconds
      interval - margin
    end

    private def register(scheduler : Scheduler, group, index : Int32) : Int32
      zone = group[:timezone]
      group[:cron_jobs].each do |entry|
        id = entry_id("cron", entry[:pattern], zone, entry[:job], entry[:args])
        scheduler.cron(entry[:pattern]) do
          enqueue_tick(id, (Time.utc.to_unix + 30) // 60, CRON_CLAIM_TTL, entry[:job], entry[:args])
        end
        index += 1
      end
      group[:recurring_jobs].each do |entry|
        id = entry_id("every", entry[:interval].to_s, zone, entry[:job], entry[:args])
        interval = entry[:interval]
        scheduler.recurring_scheduler.every(interval, "#{entry[:job]}@#{interval}##{index}", entry[:job], arguments(entry[:args])) do
          enqueue_every(id, interval, entry[:job], entry[:args])
        end
        index += 1
      end
      index
    end

    # The same text in every process that has the same entry, so they claim the same key.
    private def entry_id(kind : String, schedule : String, zone : String, job : String, args : Hash(String, YAML::Any)) : String
      Digest::SHA256.hexdigest([kind, schedule, zone, job, arguments(args)].join('\u0000'))[0, 24]
    end

    private def enqueue_claimed(key : String, ttl : Time::Span, job : String, args : Hash(String, YAML::Any)) : String?
      return unless claim(key, ttl)

      begin
        enqueue(job, args)
      rescue ex : Exception
        release(key)
        Log.error &.emit("YAML scheduler could not enqueue its job", job: job, error_class: ex.class.name, reason: ex.message)
        nil
      end
    end

    # Takes the claim on `key` for `ttl`: true when nobody holds it or this instance already does (the claim is then
    # renewed), false when another process holds it or Redis cannot be reached (logged; the run is skipped).
    def claim(key : String, ttl : Time::Span) : Bool
      return true unless store = JoobQ.store.as?(RedisStore)

      store.redis.eval(CLAIM, [key], [@owner, ttl.total_milliseconds.to_i64.to_s]) == 1
    rescue ex : Exception
      Log.error &.emit("YAML scheduler could not claim its run, skipping it", key: key, error_class: ex.class.name, reason: ex.message)
      false
    end

    # Gives back this instance's claim on `key` (after a failed enqueue) so another process can take the run; a claim
    # another process holds is left alone. Best effort.
    def release(key : String) : Nil
      JoobQ.store.as?(RedisStore).try(&.redis.eval(RELEASE, [key], [@owner]))
    rescue Exception
    end

    private def zone(name : String) : Time::Location
      Time::Location.load(name)
    rescue ex : Time::Location::InvalidLocationNameError | Time::Location::InvalidTZDataError
      raise ConfigValidationError.new("YAML scheduler timezone '#{name}' is not a known time zone")
    end

    private def validate_pattern(pattern : String) : Nil
      CronParser.new(pattern)
    rescue ex : ArgumentError
      raise ConfigValidationError.new("YAML scheduler cron pattern '#{pattern}' is invalid: #{ex.message}")
    end

    private def validate_interval(job : String, interval : Time::Span) : Nil
      return if interval >= MIN_INTERVAL

      raise ConfigValidationError.new("YAML scheduler interval for '#{job}' must be at least #{MIN_INTERVAL.total_seconds.to_i} second, got #{interval}")
    end

    private def build(job_name : String, args : Hash(String, YAML::Any)) : Job
      builder = QueueFactory.job_builder(job_name) ||
                raise ConfigValidationError.new("YAML scheduler job '#{job_name}' is not registered. Register it with QueueFactory.register_job_type(#{job_name})")
      job = builder.call(arguments(args))
      job.queue = queue_for(job_name, job.queue, args["queue"]?.try(&.as_s?))
      job
    rescue ex : JSON::Error | TypeCastError | ArgumentError
      raise ConfigValidationError.new("YAML scheduler job '#{job_name}' cannot be built from its args: #{ex.message}")
    end

    # The configured queue that serves `job_name`. A job is built from JSON (its `initialize` does not run), so its own
    # `queue` is only the default; with several queues for the type, `args: {queue: "name"}` picks one (and is honoured with one).
    private def queue_for(job_name : String, own : String, named : String?) : String
      serving = JoobQ.queues.select { |_, queue| queue.job_type == job_name }.keys
      if named
        return named if serving.includes?(named)
        raise ConfigValidationError.new("YAML scheduler job '#{job_name}' names queue '#{named}' in its args, which does not serve it (serving: #{serving.join(", ")})")
      end
      return serving.first if serving.size == 1
      return own if serving.includes?(own)

      raise ConfigValidationError.new(
        serving.empty? ? "YAML scheduler job '#{job_name}' has no configured queue that serves it" : "YAML scheduler job '#{job_name}' is served by several queues (#{serving.join(", ")}); name one with `args: {queue: \"...\"}`")
    end

    private def arguments(args : Hash(String, YAML::Any)) : String
      JSON.build do |json|
        json.object do
          args.each do |name, value|
            json.field(name) { write(json, value.raw) }
          end
        end
      end
    end

    private def write(json : JSON::Builder, value : YAML::Any::Type) : Nil
      case value
      when Hash
        json.object { value.each { |key, item| json.field(key.to_s) { write(json, item.raw) } } }
      when Array
        json.array { value.each { |item| write(json, item.raw) } }
      when String, Int64, Float64, Bool, Nil
        value.to_json(json)
      else
        json.string(value.to_s)
      end
    end
  end
end
