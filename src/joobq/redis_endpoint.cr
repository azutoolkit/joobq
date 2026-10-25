require "uri"
require "socket"
require "openssl"

module JoobQ
  # Where and how to reach a Redis server, read from a URL:
  #
  #   redis://[user:password@]host[:port][/database]      plain connection
  #   rediss://[user:password@]host[:port][/database]     TLS
  #   unix:///path/to/redis.sock[?db=N]                   unix socket
  #
  # A user name selects an ACL user (Redis 6+); a password alone is the default user's. Percent-encode `@ / : ? # %`
  # in the user name or password; a literal `+` stays a `+`. A query or fragment is refused (a credential put there
  # would be ignored without a word), except `db` on a unix URL.
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
    getter unixsocket : String?
    getter? tls : Bool
    # Whether the server's certificate chain and host name are checked (they are, unless this is turned off).
    getter? verify : Bool
    # PEM file with certificate authorities to trust in addition to the system's.
    getter ca_file : String?

    def initialize(@host : String, @port : Int32 = DEFAULT_PORT, @user : String? = nil, @password : String? = nil,
                   @database : Int32? = nil, @tls : Bool = false, @verify : Bool = true, @ca_file : String? = nil,
                   @unixsocket : String? = nil)
    end

    def self.parse(url : String, verify : Bool = true, ca_file : String? = nil) : RedisEndpoint
      uri = begin
        URI.parse(url)
      rescue URI::Error
        raise Invalid.new("Redis URL is malformed")
      end
      raise Invalid.new("Redis URL must not have a fragment") if uri.fragment

      case uri.scheme
      when "redis", "rediss"
        raise Invalid.new("Redis URL must not have a query") if uri.query
        host = uri.hostname.presence || raise Invalid.new("Redis URL has no host")
        user, password = credentials(url)
        new(host, uri.port || DEFAULT_PORT, user, password, database(uri.path), uri.scheme == "rediss", verify, ca_file)
      when "unix"
        path = uri.path.presence || raise Invalid.new("Redis URL has no socket path")
        new("localhost", DEFAULT_PORT, nil, nil, socket_database(uri.query), false, verify, ca_file, path)
      else
        raise Invalid.new("Redis URL scheme must be redis, rediss or unix")
      end
    end

    # The context for the TLS connection, or nil for a plain one. The server's certificate chain is checked against the
    # system's authorities and `ca_file`, and its host name against this endpoint's host (a certificate any trusted
    # authority issued for another host is refused), unless `verify` is off. SSLv3 and TLS 1.0 and 1.1 are refused.
    # The `redis` shard sends no server name (SNI), so a server that picks its certificate by name needs a default one.
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
      if verify?
        verify_host(context)
      else
        context.verify_mode = OpenSSL::SSL::VerifyMode::NONE
      end
      context
    end

    def to_s(io : IO) : Nil
      if path = unixsocket
        io << "unix://" << path
      else
        io << (tls? ? "rediss://" : "redis://") << (host.includes?(':') ? "[#{host}]" : host) << ':' << port
      end
      database.try { |db| io << '/' << db }
      user.try { |name| io << " (user " << name << ')' }
    end

    def inspect(io : IO) : Nil
      to_s(io)
    end

    # SSL objects copy the context's verification parameters, so the expected host set here applies to every connection.
    private def verify_host(context : OpenSSL::SSL::Context::Client) : Nil
      # an absolute name ("redis.example.com.") is the same host; OpenSSL would not match it to the certificate
      name = host.rchop('.')
      param = LibSSL.ssl_ctx_get0_param(context.to_unsafe)
      set = if Socket::IPAddress.valid?(name)
              LibCrypto.x509_verify_param_set1_ip_asc(param, name)
            else
              LibCrypto.x509_verify_param_set1_host(param, name, 0)
            end
      raise Invalid.new("Redis TLS host name cannot be set for verification") unless set == 1
    end

    # The user name and password as written, percent-decoded. The URI class decodes them as form data, which would turn
    # a literal `+` in a password into a space.
    private def self.credentials(url : String) : {String?, String?}
      authority = url.match(%r{\A[A-Za-z][A-Za-z0-9+.\-]*://([^/?#]*)}).try(&.[1]) || ""
      raise Invalid.new("Redis URL has a raw @ in its credentials: percent-encode it as %40") if authority.count('@') > 1

      userinfo = authority.rpartition('@')[0] if authority.includes?('@')
      return {nil, nil} unless userinfo

      user, separator, password = userinfo.partition(':')
      {URI.decode(user).presence, separator.empty? ? nil : URI.decode(password).presence}
    end

    private def self.database(path : String?) : Int32?
      name = path.try(&.lstrip('/')).presence
      return unless name

      name.to_i? || raise Invalid.new("Redis URL database must be a whole number")
    end

    private def self.socket_database(query : String?) : Int32?
      return unless query

      params = URI::Params.parse(query)
      raise Invalid.new("Redis unix URL accepts only the db parameter") unless params.size == 1 && params.has_key?("db")
      params["db"].to_i? || raise Invalid.new("Redis URL database must be a whole number")
    end
  end
end
