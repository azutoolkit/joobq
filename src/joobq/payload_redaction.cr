module JoobQ
  # What the management API shows of a job's arguments. A name that looks like a secret (`password`, `api_key`,
  # `Auth-Token`, at any depth) has its value replaced by `[REDACTED]` in `/joobq/jobs/retrying`, `/joobq/jobs/dead`
  # and the job data of `/joobq/errors/*`. Only the response changes; the stored job is untouched, so a retry
  # carries the real arguments. Values of `encrypted_property` are sealed in the stored job and the API never opens
  # them.
  #
  # Matching is a case-insensitive substring of the name reduced to its letters and digits on both sides (compatibility-normalized, lower-cased), so
  # `privateKey`, `private_key`, `Private-Key`, `private.key` and `private<zero-width space>key` are all hidden by the
  # entry `private_key`. A fragment also hides
  # longer names that contain it (`token` hides `tokenizer`); `auth` and `pass` are not in the default list because
  # they would hide `author` and `passenger_count`. Set the list with `config.redacted_payload_keys`, or switch the
  # whole thing off with `config.redact_api_payloads = false` (readers then see every plain argument).
  #
  # Only argument values are redacted. Free text the library records (an error's message, backtrace and cause, the
  # job's own `error`) is shown as it is, so keep secrets out of exception messages. The raw `original_job_data` of
  # an unparseable job's dead-letter stub is always withheld.
  module PayloadRedaction
    REDACTED = "[REDACTED]"

    DEFAULT_KEYS = [
      "password", "passwd", "pwd", "passphrase", "secret", "token", "api_key", "authorization", "bearer", "jwt",
      "credential", "private_key", "cookie", "card_number",
    ]

    # The field of a dead-letter stub that holds up to 1000 characters of a job that could not be parsed.
    RAW_FIELD = "original_job_data"

    # `value` with every secret-named entry replaced, at any depth. A copy; `value` is not changed.
    def self.redact(value : JSON::Any) : JSON::Any
      return value unless JoobQ.config.redact_api_payloads?
      redact(value, normalized(JoobQ.config.redacted_payload_keys))
    end

    # The same for a stored job's JSON text. Text that is not JSON cannot be checked, so it is withheld.
    def self.redact_json(text : String) : String
      return text unless JoobQ.config.redact_api_payloads?
      redact(JSON.parse(text)).to_json
    rescue JSON::ParseException
      REDACTED
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
          result[key] = secret?(key, names) || withheld?(key, item) ? JSON::Any.new(REDACTED) : redact(item, names)
        end)
      when Array
        JSON::Any.new(raw.map { |item| redact(item, names) })
      else
        value
      end
    end

    private def self.withheld?(key : String, value : JSON::Any) : Bool
      key == RAW_FIELD && !value.as_s?.nil?
    end

    private def self.secret?(key : String, names : Array(String)) : Bool
      normal = normalize(key)
      names.any? { |name| normal.includes?(name) }
    end

    private def self.normalized(names : Array(String)) : Array(String)
      names.map { |name| normalize(name) }.reject(&.empty?)
    end

    private def self.normalize(name : String) : String
      name.unicode_normalize(:nfkc).downcase.gsub(/[^\p{L}\p{N}]/, "")
    end
  end
end
