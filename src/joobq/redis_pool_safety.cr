require "redis"

# Thread safety for the connection pool behind `Redis::PooledClient`.
#
# `Redis::PooledClient` (stefanwille/crystal-redis) takes its connections from `Pool(Redis)` (ysbaddaden/pool 0.2.4,
# whose source says `FIXME: thread safety`). That pool keeps its idle connections in a plain `Array`, its counters in
# plain integers, and makes `checkout` wait by reading a byte from a pipe that many fibers read at once. None of it
# is safe once fibers run on several threads, which Crystal 1.22 does as soon as the default execution context has
# more than one worker (`crystal spec` resizes it for `CRYSTAL_WORKERS` > 1, and an application can with
# `Fiber::ExecutionContext.default.resize`). Measured with spec/redis_pool_safety_spec.cr and a stand-alone stress
# program (Crystal 1.22.1, 8 to 16 threads):
#
# * the idle Array loses entries (it ends with fewer connections than the pool started) and `pending` drifts, because
#   `shift?`, `<<` and `+=` from two threads overwrite each other. Unsynchronized writes to an Array's buffer can
#   also corrupt memory: the unfixed pool died with signal 11 in one run of the spec (address 0xfffffffefd0bb93f), and
#   that is the likeliest cause of the CI crashes seen in joobq-pro (`Redis+31` in `PooledClient#lrange`, a
#   connection object that is not valid) and joobqui (`GC_mark`/`GC_malloc`). The crash in the CI runs themselves has
#   not been reproduced, so that link is inferred;
# * a fiber waiting on the pipe can sleep with a byte waiting in it, until its read times out (seen with the mutex
#   alone, in 3 runs of 20), and one stress run faulted in `Crystal::FdLock#lock_slow`.
#
# This reopens `Pool` (joobqui builds its own pool from `ConnectionPool(Redis)`, which inherits `checkout` and
# `checkin`; its `connection`/`release` helpers keep their unlocked Hash and nothing in joobq or joobqui calls them) to
# protect the idle list and the counters with a mutex, and to wait on a `Channel` instead of the pipe. The mutex is never held across a connect
# or a wait. A failed connect now also gives its slot back (it used to leave `size` one too high for ever, so a pool
# could end up unable to grow).
#
# Remove it when the pool shard has the same fix. It replaces `initialize`, `start_all`, `checkout` and `checkin` of
# pool 0.2.4 (its `start_one` is no longer called) and keeps the instance variables that version declares; the pipe in
# `@r` and `@w` is opened and closed at once because those declarations require a value.
class Pool(T)
  def initialize(@capacity : Int32 = 5, @timeout : Float64 = 5.0, &block : -> T)
    @r, @w = IO.pipe(read_blocking: false, write_blocking: false)
    @r.close
    @w.close

    @buffer = Slice(UInt8).new(1)
    @size = 0
    @pending = @capacity
    @pool = [] of T
    @block = block
    @lock = Sync::Mutex.new
    # One token per idle connection: never more than `@capacity`, so `send` does not block.
    @tokens = Channel(Nil).new(Math.max(@capacity, 1))
  end

  def start_all
    while reserve_slot(only_when_empty: false)
      start_reserved
    end
  end

  # Checkout an instance from the pool. Blocks until an instance is available if
  # all instances are busy. Eventually raises an `IO::TimeoutError` error.
  def checkout : T
    loop do
      start_reserved if reserve_slot(only_when_empty: true)

      await_token

      taken = @lock.synchronize do
        if obj = @pool.shift?
          @pending -= 1
          {obj}
        end
      end
      return taken[0] if taken
    end
  end

  # Checkin an instance back into the pool.
  def checkin(connection : T)
    added = @lock.synchronize do
      if @pool.includes?(connection)
        false
      else
        @pool << connection
        @pending += 1
        true
      end
    end
    return unless added

    # A connection the pool did not hand out can find the channel full: keep it idle without waiting for room
    # (the original appended it and wrote to the pipe), so a misuse cannot hang the fiber.
    select
    when @tokens.send(nil)
    else
    end
  end

  # Counts one more instance as started when there is room (and, from `checkout`, nothing is idle).
  private def reserve_slot(only_when_empty : Bool) : Bool
    @lock.synchronize do
      return false if @size >= @capacity
      return false if only_when_empty && !@pool.empty?
      @size += 1
      true
    end
  end

  # Starts the instance a successful `reserve_slot` counted.
  private def start_reserved : Nil
    connection = begin
      @block.call
    rescue ex
      @lock.synchronize { @size -= 1 }
      raise ex
    end
    @lock.synchronize { @pool << connection }
    @tokens.send(nil)
  end

  # Waits for a token, which says an instance is idle, for at most `@timeout` seconds.
  private def await_token : Nil
    select
    when @tokens.receive
    else
      select
      when @tokens.receive
      when timeout(JoobQ::RedisBudget.remaining(@timeout.seconds).not_nil!)
        raise IO::TimeoutError.new("Read timed out")
      end
    end
  end
end
