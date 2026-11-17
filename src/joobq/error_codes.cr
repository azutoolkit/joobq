require "json"

module JoobQ
  # Codes are permanent: never renumber a code, never reuse a retired one, never change what a code means. Add new
  # codes at the end of their range. A website builds one page per code from `ErrorCodes.to_json`.
  #
  # Ranges: JQ-1xx configuration, JQ-2xx Redis and storage, JQ-3xx jobs and queues, JQ-4xx payload encryption,
  # JQ-5xx management API.
  struct ErrorCode
    include JSON::Serializable

    BASE_URL = "https://joobq.io/errors/"

    getter code : String
    getter title : String
    # One sentence: what the error means.
    getter summary : String
    # One or two sentences: what to do about it.
    getter fix : String
    getter url : String

    def initialize(@code : String, @title : String, @summary : String, @fix : String)
      @url = "#{BASE_URL}#{@code}"
    end

    # What a coded message ends with: ` [JQ-101] https://joobq.io/errors/JQ-101`.
    def suffix : String
      " [#{code}] #{url}"
    end

    # `message` with the suffix exactly once at the end (earlier copies, from a rebuilt message, are removed).
    def tag(message : String?) : String
      base = message.presence || title
      "#{base.gsub(suffix, "")}#{suffix}"
    end
  end

  module ErrorCodes
    private CATALOG = {
      ErrorCode.new("JQ-101", "Configuration not initialized",
        "JoobQ.config was read while no configuration was set, for example right after JoobQ.reset_config.",
        "Set the configuration before using JoobQ: JoobQ.configure, JoobQ.set_config or one of the " \
        "JoobQ.initialize_config loaders."),
      ErrorCode.new("JQ-102", "Configuration file not found",
        "The YAML configuration file given to the loader does not exist or could not be read.",
        "Check the path (a relative one is expanded from the working directory); load_from_file reports a " \
        "missing file as JQ-105 with this code inside its message."),
      ErrorCode.new("JQ-103", "Invalid YAML syntax",
        "The configuration text is not valid YAML, so nothing in it was applied.",
        "Fix the YAML at the line and column the message gives (indentation, quotes, a missing colon)."),
      ErrorCode.new("JQ-104", "Invalid configuration value",
        "A setting is missing or out of range: a YAML key the schema requires, a value of the wrong type, or a " \
        "Configure setting (retries, timeouts, batch sizes, TTLs) outside its allowed range.",
        "Correct the setting the message names to the range it states; a job class must also be registered with " \
        "QueueFactory.register_job_type before a queue names it."),
      ErrorCode.new("JQ-105", "Configuration could not be loaded",
        "Loading or mapping a configuration file or text failed; the message carries the underlying error.",
        "Read the cause in the message (it may carry its own JQ code) and fix the file, the path or the Redis " \
        "settings it names."),
      ErrorCode.new("JQ-201", "Redis is not durable enough for the durable runtime",
        "The durable delivery runtime refuses a Redis that could lose acknowledged writes or evict keys.",
        "Configure Redis with appendonly yes, appendfsync always and maxmemory-policy noeviction, or build the " \
        "runtime with production: false outside production."),
      ErrorCode.new("JQ-301", "Job class not registered",
        "A queue was requested for a job class that QueueFactory does not know, so the queue cannot be created.",
        "Call QueueFactory.register_job_type(YourJob) before the queue is created, and use the exact class name " \
        "in the YAML job_class."),
      ErrorCode.new("JQ-302", "Job failed and must not be retried",
        "The job raised NonRetryableError (or a subclass): running it again cannot succeed, so it goes to the " \
        "dead letter queue whatever retries it has left.",
        "Fix the cause the message names (bad input, a missing record), then enqueue a new job or retry it from " \
        "the dead letter queue."),
      ErrorCode.new("JQ-401", "Sealed payload value cannot be opened",
        "A value of an encrypted job property is not sealed, was sealed with a key that is not configured, is " \
        "damaged, or fails authentication.",
        "Configure every key the stored jobs were sealed with (old keys open, the first one seals); a job that " \
        "still cannot be opened was altered or belongs to another class or property."),
      ErrorCode.new("JQ-402", "Payload encryption keys missing or malformed",
        "No payload key is configured, or a key is not 32 bytes in 64 hex digits or base64, a key id is not 1 to " \
        "16 of a-z 0-9 _ -, or an id appears twice.",
        "Set payload_encryption in JoobQ.configure, or JOOBQ_PAYLOAD_KEYS / JOOBQ_PAYLOAD_KEY, to valid id:key " \
        "entries; workers keep such jobs queued until the keys are fixed."),
    }

    private INDEX = CATALOG.to_a.to_h { |entry| {entry.code, entry} }

    def self.[](code : String) : ErrorCode
      INDEX[code]? || raise KeyError.new("Unknown JoobQ error code: #{code}")
    end

    def self.[]?(code : String) : ErrorCode?
      INDEX[code]?
    end

    # Every code, ordered by code.
    def self.all : Array(ErrorCode)
      CATALOG.to_a.sort_by!(&.code)
    end

    def self.to_json : String
      all.to_json
    end

    def self.to_json(io : IO) : Nil
      all.to_json(io)
    end
  end

  # Gives an exception class a diagnostic code: `error_code "JQ-101"` in the class body. The message then ends
  # with ` [JQ-101] https://joobq.io/errors/JQ-101` exactly once; a subclass inherits the code unless it declares
  # its own. Constructors are untouched.
  module Coded
    macro error_code(code)
      def error_code : ::JoobQ::ErrorCode
        ::JoobQ::ErrorCodes[{{ code }}]
      end
    end

    abstract def error_code : ::JoobQ::ErrorCode

    def message : String?
      self.error_code.tag(super)
    end
  end
end
