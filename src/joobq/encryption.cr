require "base64"
require "json"
require "openssl"
require "openssl/cipher"

# Crystal's `OpenSSL::Cipher` can set and read a GCM tag but has no way to feed additional authenticated data (AAD);
# in OpenSSL that is an update call with no output buffer.
class OpenSSL::Cipher
  # Binds `data` to the ciphertext: it is not stored, but decrypting with different data fails. Call after `key=`
  # and `iv=` and before the first `update`.
  def joobq_authenticate(data : Bytes) : Nil
    length = 0
    raise OpenSSL::Cipher::Error.new("EVP_CipherUpdate (AAD)") if LibCrypto.evp_cipherupdate(@ctx, Pointer(UInt8).null, pointerof(length), data, data.size) != 1
  end
end

module JoobQ
  # Transparent, opt-in, field-level encryption of job payloads.
  #
  # JoobQ stores a job as JSON in Redis: in the queue list, the processing list, the retry and scheduled sets and the
  # dead-letter set. Anyone who can read Redis, a backup or an export can read the job's arguments. A property
  # declared with `encrypted_property` is written as an AES-256-GCM sealed string instead, and is read back to its
  # plain value when a worker loads the job, before `perform` runs:
  #
  # ```
  # class ChargeJob
  #   include JoobQ::Job
  #
  #   property order_id : Int64 = 0 # stays readable (useful for the console and for debugging)
  #   encrypted_property card_token : String = ""
  #   encrypted_property billing : Hash(String, String)? = nil
  #
  #   def perform
  #     charge(card_token) # plain text here
  #   end
  # end
  # ```
  #
  # What this is: confidentiality of those properties at rest in Redis, and integrity: a sealed value that is moved
  # to another job class or field, or altered, is refused. The keys are not in Redis.
  #
  # What it is not: encryption of jobs in general (only the properties you declare); protection while the job runs,
  # in your own logs or in the messages your `perform` raises (the library scrubs the plain values of encrypted
  # properties from the error messages and backtraces it records, but it cannot know what you print); hiding the
  # size of a value.
  #
  # ## Keys
  #
  # One key (32 bytes, as 64 hex digits or base64, e.g. `openssl rand -base64 32`) is *current* and seals; any
  # number of older keys only open. A key is written `id:key`, the id being 1 to 16 characters of `a-z 0-9 _ -`
  # (a bare key without an id gets the id `default`). The id is stored with every sealed value, which is how a worker
  # knows which key to use.
  #
  # ```
  # JoobQ.configure do
  #   payload_encryption current: "2026a:#{ENV["NEW_KEY"]}", previous: ["2025:#{ENV["OLD_KEY"]}"]
  # end
  # ```
  #
  # Without that call the keys come from the environment: `JOOBQ_PAYLOAD_KEYS` (comma separated `id:key` entries, the
  # first one current) or, as the simplest form, `JOOBQ_PAYLOAD_KEY` (one entry). The environment is read on first
  # use; changing it needs a restart.
  #
  # To rotate: add the new key first, deploy, and keep the old one until no job sealed with it can be in Redis
  # (queues, retries, scheduled jobs, dead letters); a job that is retried is written again with the current key.
  # A value sealed with a key that is gone cannot be opened.
  #
  # ## Failure mode
  #
  # A job is never run with a value it could not open.
  #
  # * Problems with the *job*: an unknown key id, a bad tag (wrong class or field, altered), a damaged value. The
  #   worker moves it to the dead-letter set as the job itself (sealed values untouched, status Dead) with error
  #   type `decryption_error` and a message that names the class, the field and the reason, never a value. It can
  #   be redriven (`DeadLetterQueue#redrive`, the API's retry) once the key is back, and runs then.
  # * Problems with this *process's keys*: none configured, or `JOOBQ_PAYLOAD_KEYS` malformed
  #   (`Encryption::ConfigurationError`). The job is fine, so it is not dead-lettered: the worker logs, waits five
  #   seconds and puts it back on its queue. A queue of a job class with encrypted properties refuses to start
  #   (`Queue#start` raises) without valid keys, and enqueuing raises to the caller.
  #
  # Payloads written before the property was encrypted (plain values) are read as they are, and written sealed the
  # next time the job is stored. `JoobQ.config.allow_plaintext_payloads = false` makes the *worker* refuse them
  # (`Queue#add` and the HTTP API still accept them: they are about to be sealed). While it is true, anyone who can
  # write to Redis can put an unsealed value in a job and it will run: sealing gives confidentiality, and integrity
  # only against tampering with a sealed value.
  #
  # ## Limits worth knowing
  #
  # * The associated data is the class and the property, not the job id: a sealed value can be copied between two
  #   jobs of the same class and property by someone who can write to Redis.
  # * Nonces are random 96 bit values, so keep to about 2^32 seals per key (billions of values), then rotate.
  # * Values shorter than `MIN_SCRUB` characters are not scrubbed from recorded errors.
  #
  # ## Format
  #
  # `jqe1:<key id>:<base64url (no padding) of nonce, ciphertext and tag>`: AES-256-GCM, a fresh random 96 bit nonce
  # per value, the additional authenticated data being `joobq/payload/v1`, the job class and the property name
  # (separated by NUL). A `String` is sealed as it is; any other type is sealed as its JSON text. `nil` is stored
  # as `null`. Renaming the class or the property makes existing sealed values unreadable: pass `job_name:` to
  # `encrypted_property` to keep the name stable.
  module Encryption
    # Begins every sealed value; used to recognise one without any key.
    PREFIX     = "jqe1:"
    ENV_KEY    = "JOOBQ_PAYLOAD_KEY"
    ENV_KEYS   = "JOOBQ_PAYLOAD_KEYS"
    NONCE_LEN  = 12
    TAG_LEN    = 16
    KEY_LEN    = 32
    KEY_ID     = /\A[a-z0-9_-]{1,16}\z/
    DEFAULT_ID = "default"
    # Replaces a plain value in text the library records.
    REDACTED = "[REDACTED]"
    # Plain values shorter than this are not scrubbed from messages: a one- or two-character value would match
    # everywhere and make every message unreadable. Do not put a secret that short in a job and expect it hidden.
    MIN_SCRUB = 4

    # Raised for anything wrong with a sealed value or the keys. It is a `JSON::Error` so a worker that fails to
    # load a job treats it like any unreadable payload (dead letter), but its message never has a value in it.
    class Error < JSON::Error
    end

    # The keys are missing or malformed: a problem with this process's configuration, not with the job. A worker
    # leaves such a job in the queue (and backs off) instead of dead-lettering it, and a queue of a job class with
    # encrypted properties refuses to start without valid keys.
    class ConfigurationError < Error
    end

    # The configured keys: the current one (seals) and the old ones (open only).
    class Keys
      getter current_id : String

      def initialize(@keys : Hash(String, Bytes), @current_id : String)
      end

      # `entries` is a list of `id:key` texts, the first one current.
      def self.parse(entries : Array(String), source : String = "payload keys") : Keys
        entries = entries.map(&.strip).reject(&.empty?)
        raise ConfigurationError.new("#{source}: no key given") if entries.empty?

        keys = {} of String => Bytes
        first = nil
        entries.each do |entry|
          id, material = split(entry, source)
          raise ConfigurationError.new("#{source}: key id #{id.inspect} appears twice") if keys.has_key?(id)

          keys[id] = decode(id, material, source)
          first ||= id
        end
        new(keys, first.not_nil!)
      end

      def self.parse(text : String, source : String = "payload keys") : Keys
        parse(text.split(','), source)
      end

      def self.from_env : Keys?
        if many = ENV[ENV_KEYS]?.presence
          parse(many, ENV_KEYS)
        elsif one = ENV[ENV_KEY]?.presence
          parse([one], ENV_KEY)
        end
      end

      private def self.split(entry : String, source : String) : {String, String}
        id, colon, material = entry.partition(':')
        return {DEFAULT_ID, entry} if colon.empty?

        raise ConfigurationError.new("#{source}: a key id is 1 to 16 of a-z 0-9 _ -") unless KEY_ID.matches?(id)

        {id, material.strip}
      end

      # The key itself is never put in a message.
      private def self.decode(id : String, material : String, source : String) : Bytes
        bytes = if material.size == KEY_LEN * 2 && material.each_char.all?(&.hex?)
                  material.hexbytes
                else
                  begin
                    Base64.decode(material.tr("-_", "+/"))
                  rescue Base64::Error
                    raise ConfigurationError.new("#{source}: key #{id.inspect} is neither 64 hex digits nor base64")
                  end
                end
        raise ConfigurationError.new("#{source}: key #{id.inspect} must be #{KEY_LEN} bytes (it is #{bytes.size})") unless bytes.size == KEY_LEN

        bytes
      end

      def [](id : String) : Bytes?
        @keys[id]?
      end

      def ids : Array(String)
        @keys.keys
      end
    end

    @@env_keys : Keys?
    @@env_read = false
    @@env_mutex = Sync::Mutex.new

    # The keys in force: `JoobQ.config.payload_keys`, else the environment (read once).
    def self.keys : Keys
      JoobQ.config.payload_keys || env_keys || raise ConfigurationError.new(
        "no payload encryption key is configured (payload_encryption in JoobQ.configure, or #{ENV_KEYS} / #{ENV_KEY})")
    end

    private def self.env_keys : Keys?
      @@env_mutex.synchronize do
        unless @@env_read
          @@env_keys = Keys.from_env # raises (and stays unread) when the variable is malformed
          @@env_read = true
        end
        @@env_keys
      end
    end

    # Forgets the keys read from the environment, so the next use reads it again (specs, tools).
    def self.reset_env_keys : Nil
      @@env_mutex.synchronize do
        @@env_keys = nil
        @@env_read = false
      end
    end

    @@key_backoff = 5.seconds

    # How long a worker waits before it puts back a job it could not open for want of a keys (see ConfigurationError).
    def self.key_backoff : Time::Span
      @@key_backoff
    end

    def self.key_backoff=(value : Time::Span)
      @@key_backoff = value
    end

    @@strict = {} of Fiber => Bool
    @@strict_mutex = Sync::Mutex.new

    # Runs the block with plain payload values refused when `allow_plaintext_payloads` is false. Only the worker
    # path uses it: `Queue#add` and the HTTP API still accept plain values (they are about to be sealed).
    def self.strict(&)
      fiber = Fiber.current
      @@strict_mutex.synchronize { @@strict[fiber] = true }
      begin
        yield
      ensure
        @@strict_mutex.synchronize { @@strict.delete(fiber) }
      end
    end

    def self.strict? : Bool
      @@strict_mutex.synchronize { @@strict.has_key?(Fiber.current) }
    end

    def self.sealed?(value : String) : Bool
      value.starts_with?(PREFIX)
    end

    # The additional authenticated data of a property.
    def self.context(job : String, field : String) : Bytes
      "joobq/payload/v1\0#{job}\0#{field}".to_slice
    end

    def self.seal(plain : String, job : String, field : String, keys : Keys = self.keys) : String
      id = keys.current_id
      nonce = Random::Secure.random_bytes(NONCE_LEN)
      cipher = OpenSSL::Cipher.new("aes-256-gcm")
      cipher.encrypt
      cipher.key = keys[id].not_nil!
      cipher.iv = nonce
      cipher.joobq_authenticate(context(job, field))
      body = IO::Memory.new
      body.write(nonce)
      body.write(cipher.update(plain))
      body.write(cipher.final)
      body.write(cipher.gcm_tag)
      "#{PREFIX}#{id}:#{Base64.urlsafe_encode(body.to_slice, padding: false)}"
    end

    # Raises `Error` (without any value in its message) for a value that is not sealed, was sealed for another class
    # or property, was altered, or was sealed with a key that is not configured.
    def self.open(sealed : String, job : String, field : String, keys : Keys = self.keys) : String
      raise Error.new("#{job}.#{field} is not a sealed value") unless sealed?(sealed)

      id, colon, encoded = sealed[PREFIX.size..].partition(':')
      key = colon == ":" ? keys[id] : nil
      raise Error.new("#{job}.#{field} was sealed with key #{clean(id).inspect}, which is not configured") unless key

      raw = begin
        Base64.decode(encoded.tr("-_", "+/"))
      rescue Base64::Error
        raise Error.new("#{job}.#{field}: the sealed value is damaged")
      end
      raise Error.new("#{job}.#{field}: the sealed value is damaged") if raw.size < NONCE_LEN + TAG_LEN

      cipher = OpenSSL::Cipher.new("aes-256-gcm")
      cipher.decrypt
      cipher.key = key
      cipher.iv = raw[0, NONCE_LEN]
      cipher.joobq_authenticate(context(job, field))
      plain = IO::Memory.new
      plain.write(cipher.update(raw[NONCE_LEN, raw.size - NONCE_LEN - TAG_LEN]))
      cipher.gcm_tag = raw[raw.size - TAG_LEN, TAG_LEN]
      plain.write(cipher.final)
      String.new(plain.to_slice)
    rescue OpenSSL::Cipher::Error
      raise Error.new("#{job}.#{field} could not be opened: wrong key, other class or property, or altered")
    end

    # A key id read from a stored value is attacker-controlled text: keep a message tidy.
    private def self.clean(id : String) : String
      id.gsub(/[^a-z0-9_-]/, "?")[0, 16]
    end

    # `text` with every given plain value replaced by `REDACTED`, longest first (so a value that contains another is
    # replaced whole). Used on what the library records about a failure.
    def self.scrub(text : String, secrets : Array(String)) : String
      secrets.each do |secret|
        text = text.gsub(secret, REDACTED) if secret.size >= MIN_SCRUB
      end
      text
    end

    # Every form in which `value` could show up in a message: itself, its `to_s`, `inspect` and JSON text, and the
    # leaf strings and numbers inside a hash or array. Longest first.
    def self.secret_forms(value) : Array(String)
      forms = [] of String
      return forms if value.nil?

      forms << value.to_s << value.inspect << value.to_json
      collect_leaves(JSON.parse(value.to_json), forms)
      forms.uniq!.reject! { |form| form.size < MIN_SCRUB }
      forms.sort_by! { |form| -form.size }
    end

    private def self.collect_leaves(any : JSON::Any, forms : Array(String)) : Nil
      case raw = any.raw
      when Hash  then raw.each_value { |item| collect_leaves(item, forms) }
      when Array then raw.each { |item| collect_leaves(item, forms) }
      when Nil   then nil
      else            forms << raw.to_s
      end
    end

    def self.scrub(text : String?, secrets : Array(String)) : String?
      text.try { |value| scrub(value, secrets) }
    end

    # The JSON converter behind `encrypted_property`: `converter: Field(String).new("JobClass", "name")`. The names
    # are part of the stored value's identity (they are the associated data).
    struct Field(T)
      def initialize(@job : String, @field : String)
      end

      def from_json(pull : JSON::PullParser) : T
        any = JSON::Any.new(pull)
        text = any.as_s?
        if text && Encryption.sealed?(text)
          plain = Encryption.open(text, @job, @field)
          # A `String` (or `String?`) is sealed as it is, anything else as its JSON text.
          {% if T.union_types.map(&.stringify).reject { |t| t == "Nil" } == ["String"] %}
            return plain
          {% else %}
            return T.from_json(plain)
          {% end %}
        end
        # Not sealed: a payload written before encryption, or a value someone put there.
        if !any.raw.nil? && !JoobQ.config.allow_plaintext_payloads? && Encryption.strict?
          raise Error.new("#{@job}.#{@field} is not encrypted and plain payloads are not allowed")
        end
        T.from_json(any.to_json)
      end

      def to_json(value : T, builder : JSON::Builder) : Nil
        if value.nil?
          builder.null
        else
          builder.string(Encryption.seal(value.is_a?(String) ? value : value.to_json, @job, @field))
        end
      end
    end
  end
end

module JoobQ::Job
  # Declares a job property whose value is sealed in the stored payload (see `JoobQ::Encryption`). Use it inside a
  # class that includes `JoobQ::Job`, in place of `property`:
  #
  # ```
  # encrypted_property card_token : String = ""
  # ```
  #
  # `job_name:` fixes the class name that is bound to the value (default: the class's own name).
  macro encrypted_property(decl, job_name = nil)
    @[JSON::Field(converter: ::JoobQ::Encryption::Field({{decl.type}}).new({{job_name || @type.name.stringify}}, {{decl.var.stringify}}))]
    property {{decl}}
  end
end
