module JoobQ
  # The names of the Redis keys JoobQ owns. Every key lives under `PREFIX`, one versioned namespace, so JoobQ cannot
  # collide with another application on a shared Redis, and a later layout change is told apart by its version.
  # Code that needs a key asks here rather than building the string: a queue's list is `Keys.queue(name)`, never
  # the bare queue name. The leased-delivery runtime keeps its own state under `PREFIX:<namespace>:` (see
  # `RESERVED_NAMESPACES`).
  module Keys
    PREFIX = "joobq:v1"

    DELAYED_JOBS       = "#{PREFIX}:delayed_jobs"
    DEAD_LETTER        = "#{PREFIX}:dead_letter"
    DEAD_LETTER_COUNTS = "#{PREFIX}:dead_letter:counts"
    PROCESSING         = "#{PREFIX}:processing"
    PROCESSING_OWNERS  = "#{PREFIX}:processing-owners"
    ERROR_COUNTS       = "#{PREFIX}:error_counts"
    RECENT_ERRORS      = "#{PREFIX}:recent_errors"
    ERROR_INDEX        = "#{PREFIX}:error_index"
    WORKERS            = "#{PREFIX}:workers"
    EVENTS             = "#{PREFIX}:events"
    EVENTS_LIVE        = "#{PREFIX}:events:live"
    EVENTS_TRIM_LOCK   = "#{PREFIX}:events:trim_lock"
    FAILED_JOBS        = "#{PREFIX}:failed_jobs"
    LMOVE_PROBE        = "#{PREFIX}:lmove-probe"
    LATENCY            = "#{PREFIX}:stats:latency"

    # The second segment of every key above and below: a delivery namespace of the same name would share a key space
    # with it, so `Delivery::Ledger` refuses these as namespaces.
    RESERVED_NAMESPACES = %w[queue delayed_jobs dead_letter processing processing-owners error_counts recent_errors
      error_index worker workers events failed_jobs lmove-probe stats retry_lock schedule paused config delivery-bridge]

    # Refuses a delivery namespace (`Delivery::Ledger`, `Journal`, `Backup`) that is named like one of the families
    # above, because it would share a key space with them, unless it already holds delivery data: a namespace that
    # existed before this check keeps working (with a warning), so an upgrade does not break it. Delivery keys are
    # `PREFIX:<namespace>:<queue>:records`, `PREFIX:<namespace>:maintenance` and `PREFIX:<namespace>:journal:<name>`.
    def self.check_namespace!(redis : Redis::PooledClient, namespace : String) : Nil
      return unless RESERVED_NAMESPACES.includes?(namespace)

      patterns = ["#{PREFIX}:#{namespace}:*:records", "#{PREFIX}:#{namespace}:maintenance", "#{PREFIX}:#{namespace}:journal:*"]
      if patterns.any? { |pattern| any_key?(redis, pattern) }
        Log.for("keys").warn { "delivery namespace #{namespace.inspect} is named like a JoobQ key family; it keeps working because it already holds data, but a new namespace of that name is refused: rename it when you can" }
        return
      end
      raise ArgumentError.new("namespace #{namespace.inspect} is reserved for JoobQ's own keys")
    end

    private def self.any_key?(redis : Redis::PooledClient, pattern : String) : Bool
      cursor = "0"
      loop do
        reply = redis.scan(cursor, match: pattern, count: 1000)
        cursor = reply[0].as(String)
        return true unless reply[1].as(Array).empty?
        return false if cursor == "0"
      end
    end

    # The list of the jobs waiting in the queue called *name*: producers RPUSH to its tail, workers claim from its head.
    def self.queue(name : String) : String
      "#{PREFIX}:queue:#{name}"
    end

    # The processing list of the legacy shared kind (`PROCESSING:<queue>`), and of one owning process (`...:<owner>`).
    def self.processing(queue : String) : String
      "#{PROCESSING}:#{queue}"
    end

    def self.processing(queue : String, owner : String) : String
      "#{PROCESSING}:#{queue}:#{owner}"
    end

    # A counter hash such as `stats:processed` (one field per queue, or `global`).
    def self.stat(name : String) : String
      "#{PREFIX}:stats:#{name}"
    end

    def self.retry_lock(jid) : String
      "#{PREFIX}:retry_lock:#{jid}"
    end

    # The claim of one tick of a YAML `schedulers:` entry (`entry` is the entry's digest, `tick` its minute or interval
    # number): the process that sets it enqueues the tick's job.
    def self.schedule_tick(entry : String, tick : Int64) : String
      "#{PREFIX}:schedule:#{entry}:#{tick}"
    end

    # The claim of a recurring YAML `schedulers:` entry: set for about one interval by the process that enqueues it.
    def self.schedule_claim(entry : String) : String
      "#{PREFIX}:schedule:#{entry}"
    end

    # The pause flag and the desired-concurrency hash of a queue.
    def self.paused(queue : String) : String
      "#{PREFIX}:paused:#{queue}"
    end

    def self.config(queue : String) : String
      "#{PREFIX}:config:#{queue}"
    end

    # The heartbeat entry of a worker process (`id` is `<host>:<pid>`).
    def self.worker(id : String) : String
      "#{PREFIX}:worker:#{id}"
    end

    # Set while a queue is bound to leased delivery (written by joobq-pro's delivery bridge).
    def self.delivery_bridge(queue : String) : String
      "#{PREFIX}:delivery-bridge:#{queue}"
    end

    # The 0.6 name of that marker, which an unchanged joobq-pro still writes. `Queue#start` reads it too, so the guard
    # against a legacy worker on a leased queue stays on; remove it at 1.0, once joobq-pro uses `delivery_bridge`.
    def self.legacy_delivery_bridge(queue : String) : String
      "joobq:delivery-bridge:#{queue}"
    end
  end
end
