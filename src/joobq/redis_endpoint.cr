require "uri"
require "openssl"

module JoobQ
  # Where and how to reach a Redis server, read from a `redis://` or `rediss://` URL:
  #
  #   redis://[user:password@]host[:port][/database]      plain connection
  #   rediss://[user:password@]host[:port][/database]     TLS
  #
  # A user name selects an ACL user (Redis 6+); a password alone is the default user's. Characters in the user name
  # or password that mean something in a URL (`@ / : ? # %`) must be percent-encoded.
  #
  # The password never appears in `to_s`, `inspect` or an error message, and neither does the URL.
  class RedisEndpoint
    # The URL cannot be used. The message says what is wrong and never repeats the URL.
    class Invalid < Exception
    end

    DEFAULT_PORT = 6379

    getter host : String
    getter port : Int32
    getter user : String?
    getter password : String?
    getter database : Int32?
    getter? tls : Bool
    # Whether the server's certificate chain is checked (it is, unless this is turned off).
    getter? verify : Bool
    # PEM file with the certificate authorities to trust instead of the system's.
    getter ca_file : String?

    def initialize(@host : String, @port : Int32 = DEFAULT_PORT, @user : String? = nil, @password : String? = nil,
                   @database : Int32? = nil, @tls : Bool = false, @verify : Bool = true, @ca_file : String? = nil)
    end

    def self.parse(url : String, verify : Bool = true, ca_file : String? = nil) : RedisEndpoint
      uri = begin
        URI.parse(url)
      rescue URI::Error
        raise Invalid.new("Redis URL is malformed")
      end

      tls = case uri.scheme
            when "redis"  then false
            when "rediss" then true
            else
              raise Invalid.new("Redis URL scheme must be redis or rediss")
            end
      host = uri.host.presence || raise Invalid.new("Redis URL has no host")

      new(host, uri.port || DEFAULT_PORT, uri.user.presence, uri.password.presence, database(uri.path), tls, verify, ca_file)
    end

    # The context for the TLS connection, or nil for a plain one. The certificate chain is checked against `ca_file`
    # (or the system's authorities) unless `verify` is off; SSLv3 and TLS 1.0 and 1.1 are refused. The `redis` shard
    # does not pass a host name to the handshake, so the server's name is not matched against its certificate: point
    # `ca_file` at a CA that signs only your Redis if that matters.
    def ssl_context : OpenSSL::SSL::Context::Client?
      return unless tls?

      context = OpenSSL::SSL::Context::Client.new
      context.add_options(OpenSSL::SSL::Options::NO_SSL_V2 | OpenSSL::SSL::Options::NO_SSL_V3 |
                          OpenSSL::SSL::Options::NO_TLS_V1 | OpenSSL::SSL::Options::NO_TLS_V1_1)
      ca_file.try do |path|
        begin
          context.ca_certificates = path
        rescue OpenSSL::Error
          raise Invalid.new("Redis CA file cannot be read")
        end
      end
      context.verify_mode = OpenSSL::SSL::VerifyMode::NONE unless verify?
      context
    end

    def to_s(io : IO) : Nil
      io << (tls? ? "rediss://" : "redis://") << host << ':' << port
      database.try { |db| io << '/' << db }
      user.try { |name| io << " (user " << name << ')' }
    end

    def inspect(io : IO) : Nil
      to_s(io)
    end

    private def self.database(path : String?) : Int32?
      name = path.try(&.lstrip('/')).presence
      return unless name

      name.to_i? || raise Invalid.new("Redis URL database must be a whole number")
    end
  end
end
