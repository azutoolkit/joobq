module JoobQ
  # What the management API shows of a job's arguments. A name that looks like a secret (`password`, `api_key`,
  # `Auth-Token`, at any depth) has its value replaced by `[REDACTED]` in `/joobq/jobs/retrying`, `/joobq/jobs/dead`
  # and the job data of `/joobq/errors/*`. Only the response changes; the stored job is untouched, so a retry
  # carries the real arguments. Values of `encrypted_property` are sealed in the stored job and the API never opens
  # them.
  #
  # Matching is a case-insensitive substring of the name after `-` and spaces become `_`, so an argument named
  # `author` is hidden by the entry `auth`. Set the list with `config.redacted_payload_keys`, or switch the whole
  # thing off with `config.redact_api_payloads = false` (readers then see every plain argument).
  module PayloadRedaction
    REDACTED = "[REDACTED]"

    DEFAULT_KEYS = [
      "password", "passwd", "secret", "token", "api_key", "apikey", "authorization",
      "credential", "private_key", "cookie", "card_number",
    ]

    # `value` with every secret-named entry replaced, at any depth. A copy; `value` is not changed.
    def self.redact(value : JSON::Any) : JSON::Any
      return value unless JoobQ.config.redact_api_payloads?
      redact(value, normalized(JoobQ.config.redacted_payload_keys))
    end

    # The same for a stored job's JSON text; text that is not JSON is returned as it is.
    def self.redact_json(text : String) : String
      return text unless JoobQ.config.redact_api_payloads?
      redact(JSON.parse(text)).to_json
    rescue JSON::ParseException
      text
    end

    # The error record as the API shows it: `job_data` goes through `redact_json`.
    def self.redact(context : ErrorContext) : JSON::Any
      any = JSON.parse(context.to_json)
      return any unless JoobQ.config.redact_api_payloads?
      if data = context.job_data
        hash = any.as_h
        hash["job_data"] = JSON::Any.new(redact_json(data))
        any = JSON::Any.new(hash)
      end
      any
    end

    private def self.redact(value : JSON::Any, names : Array(String)) : JSON::Any
      case raw = value.raw
      when Hash
        JSON::Any.new(raw.each_with_object({} of String => JSON::Any) do |(key, item), result|
          result[key] = secret?(key, names) ? JSON::Any.new(REDACTED) : redact(item, names)
        end)
      when Array
        JSON::Any.new(raw.map { |item| redact(item, names) })
      else
        value
      end
    end

    private def self.secret?(key : String, names : Array(String)) : Bool
      normal = normalize(key)
      names.any? { |name| normal.includes?(name) }
    end

    private def self.normalized(names : Array(String)) : Array(String)
      names.map { |name| normalize(name) }.reject(&.empty?)
    end

    private def self.normalize(name : String) : String
      name.downcase.tr("- ", "__")
    end
  end
end
