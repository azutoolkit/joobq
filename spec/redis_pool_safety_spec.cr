require "spec"
require "../src/joobq/redis_pool_safety"

# `Redis::PooledClient` takes its connections from `Pool`, which keeps them in an Array and counts them in plain
# integers. These examples run the pool from fibers on 8 threads of their own execution context (so they do not
# depend on `CRYSTAL_WORKERS`) and then check what a lost update would break: the idle list must hold every
# connection the pool started, once, and the counters must agree with it.
private class PoolSpecConn
  getter busy = Atomic(Int32).new(0)
  getter payload = Array(Int32).new(8) { |i| i }
end

private def hammer(pool : Pool(PoolSpecConn), fibers : Int32, iterations : Int32) : {Int32, Int32}
  context = Fiber::ExecutionContext::Parallel.new("pool-spec", 8)
  overlaps = Atomic(Int32).new(0)
  timeouts = Atomic(Int32).new(0)
  done = Channel(Nil).new
  fibers.times do
    context.spawn do
      iterations.times do
        conn = begin
          pool.checkout
        rescue IO::TimeoutError
          timeouts.add(1)
          break
        end
        # Two fibers holding one connection, or a connection that is not intact any more.
        overlaps.add(1) if conn.busy.add(1) != 0 || conn.payload[7] != 7
        Fiber.yield if rand(4) == 0
        conn.busy.sub(1)
        pool.checkin(conn)
      end
    ensure
      done.send(nil)
    end
  end
  fibers.times do
    select
    when done.receive
    when timeout(120.seconds)
      raise "a pool fiber did not finish within 120 s (a checkout or checkin is stuck)"
    end
  end
  {overlaps.get, timeouts.get}
end

describe Pool do
  it "keeps every connection, once, and its counters straight when fibers on several threads share it" do
    # The failure is a race, so one round may get away with it; the fixed pool passes every round.
    6.times do
      pool = Pool(PoolSpecConn).new(capacity: 8, timeout: 20.0) { PoolSpecConn.new }
      overlaps, timeouts = hammer(pool, fibers: 64, iterations: 4_000)

      overlaps.should eq(0)
      timeouts.should eq(0)
      # It starts a connection only when none is idle, so it may not have started all 8.
      pool.size.should be <= 8
      idle = pool.@pool
      idle.size.should eq(pool.size)
      idle.map(&.object_id).uniq.size.should eq(pool.size)
      pool.pending.should eq(8) # capacity less the connections in use, and none is
    end
  end

  it "starts connections on demand, never more than its capacity" do
    started = Atomic(Int32).new(0)
    pool = Pool(PoolSpecConn).new(capacity: 4, timeout: 5.0) do
      started.add(1)
      sleep 1.millisecond
      PoolSpecConn.new
    end
    hammer(pool, fibers: 32, iterations: 50)

    started.get.should be <= 4
    pool.size.should eq(started.get)
    pool.pending.should eq(4)
  end

  it "gives the slot back when a connection cannot be started" do
    attempts = 0
    pool = Pool(PoolSpecConn).new(capacity: 1, timeout: 0.5) do
      attempts += 1
      raise "cannot connect" if attempts == 1
      PoolSpecConn.new
    end

    expect_raises(Exception, "cannot connect") { pool.checkout }
    pool.size.should eq(0)

    conn = pool.checkout
    pool.size.should eq(1)
    pool.checkin(conn)
    pool.pending.should eq(1)
  end

  it "ignores a connection checked in twice" do
    pool = Pool(PoolSpecConn).new(capacity: 2, timeout: 0.5) { PoolSpecConn.new }
    conn = pool.checkout
    pool.checkin(conn)
    pool.checkin(conn)

    pool.pending.should eq(2)
    pool.@pool.size.should eq(1)
  end

  it "raises a timeout when every connection is in use" do
    pool = Pool(PoolSpecConn).new(capacity: 1, timeout: 0.2) { PoolSpecConn.new }
    conn = pool.checkout

    expect_raises(IO::TimeoutError) { pool.checkout }
    pool.checkin(conn)
    pool.checkout.should be(conn)
  end
end
