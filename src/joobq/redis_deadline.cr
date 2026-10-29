# One monotonic budget follows a pooled operation through checkout, connection
# setup and every socket read/write. No timeout fiber may outlive the pool lease.
class Fiber
  property joobq_redis_deadline : Time::Instant?
end

module JoobQ
  module RedisBudget
    def self.remaining(fallback : Time::Span? = nil) : Time::Span?
      if deadline = Fiber.current.joobq_redis_deadline
        left = deadline - Time.instant
        raise IO::TimeoutError.new("Redis operation deadline exceeded") unless left > Time::Span.zero
        fallback ? Math.min(left, fallback) : left
      else
        fallback
      end
    end
  end

  class DeadlineIO < IO
    include IO::Buffered

    def initialize(@io : IO, @socket : Socket, @command_timeout : Time::Span?)
    end

    private def budget : Nil
      timeout = RedisBudget.remaining(@command_timeout)
      @socket.read_timeout = timeout
      @socket.write_timeout = timeout
    end

    def unbuffered_read(slice : Bytes) : Int32
      budget
      @io.read(slice)
    end

    def unbuffered_write(slice : Bytes) : Nil
      budget
      @io.write(slice)
    end

    def unbuffered_flush : Nil
      budget
      @io.flush
    end

    def unbuffered_close : Nil
      # Close the transport first: aborting a failed pipeline must not flush more
      # mutations or block on TLS shutdown while returning its pool slot.
      @socket.close
      @io.close unless @io.same?(@socket)
    rescue IO::Error | OpenSSL::Error
    end

    def unbuffered_rewind : Nil
      raise IO::Error.new("Redis socket cannot rewind")
    end
  end

  class DeadlineUNIXSocket < UNIXSocket
    def initialize(path : String, timeout : Time::Span?)
      super(Socket::Family::UNIX, Socket::Type::STREAM)
      connect(Socket::UNIXAddress.new(path), timeout: timeout)
    rescue ex
      close
      raise ex
    end
  end

  class DeadlineConnection < Redis::Connection
    def initialize(host : String, port : Int32, unixsocket : String?, ssl_context : OpenSSL::SSL::Context::Client?,
                   dns_timeout : Time::Span?, connect_timeout : Time::Span?, command_timeout : Time::Span?)
      @socket = Redis::SocketWrapper.new do
        if path = unixsocket
          # UNIXSocket construction has no DNS phase. The socket-level connect
          # still uses the remainder of the same operation budget.
          wire = DeadlineUNIXSocket.new(path, RedisBudget.remaining(connect_timeout))
        else
          wire = connect_tcp(host, port, dns_timeout, connect_timeout)
        end
        wire.sync = true
        budgeted = DeadlineIO.new(wire, wire, command_timeout)
        if context = ssl_context
          budgeted.sync = true
          ssl = OpenSSL::SSL::Socket::Client.new(budgeted, context, sync_close: true, hostname: host)
          ssl.sync = true
          DeadlineIO.new(ssl, wire, command_timeout)
        else
          budgeted
        end
      rescue ex
        wire.try(&.close)
        raise ex
      end
    end

    def close
      @socket.abort
    end

    private def connect_tcp(host, port, dns_timeout, connect_timeout) : TCPSocket
      addresses = Socket::Addrinfo.tcp(host, port, timeout: RedisBudget.remaining(dns_timeout))
      last_error = nil.as(Exception?)
      addresses.each do |address|
        socket = TCPSocket.new(address.family)
        begin
          socket.connect(address, timeout: RedisBudget.remaining(connect_timeout))
          return socket
        rescue ex
          socket.close
          last_error = ex
        end
      end
      raise last_error || IO::Error.new("Redis endpoint has no usable address")
    end
  end
end

struct Redis::SocketWrapper
  def abort : Nil
    return unless @connected
    @connected = false
    if socket = @socket.as?(JoobQ::DeadlineIO)
      socket.unbuffered_close
    else
      @socket.close
    end
  end

  def initialize(@socket : JoobQ::DeadlineIO)
    @connected = true
  end
end
