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
      error_index worker workers events failed_jobs lmove-probe stats retry_lock paused config delivery-bridge]

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
  end
end
