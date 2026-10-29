require "./spec_helper"

describe "Redis connection GC compatibility" do
  it "does not perform fiber-bound IO from a finalizer on a bare thread" do
    connection = Redis::Connection.new(ENV.fetch("REDIS_HOST"), ENV.fetch("REDIS_PORT").to_i, nil, nil)
    # A raw Crystal thread has no Fiber::ExecutionContext, just like the monitor
    # thread on which Boehm ran the dependency's finalizer in the failing suite.
    failure = Atomic(Bool).new(false)
    Thread.new do
      connection.finalize
    rescue
      failure.set(true)
    end.join
    failure.get.should be_false
    connection.send(["PING"])
    connection.receive.should eq("PONG")
  ensure
    connection.try(&.close)
  end
end
