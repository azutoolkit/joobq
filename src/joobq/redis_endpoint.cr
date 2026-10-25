require "uri"

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

    def initialize(@host : String, @port : Int32 = DEFAULT_PORT, @user : String? = nil, @password : String? = nil,
                   @database : Int32? = nil, @tls : Bool = false)
    end

    def self.parse(url : String) : RedisEndpoint
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

      new(host, uri.port || DEFAULT_PORT, uri.user.presence, uri.password.presence, database(uri.path), tls)
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
