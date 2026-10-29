require "./spec_helper"

private def read_redis_request(socket : TCPSocket) : Array(String)?
  line = socket.gets || return
  count = line[1..].to_i
  Array(String).new(count) do
    size = socket.gets.not_nil![1..].to_i
    value = socket.read_string(size)
    socket.read_string(2)
    value
  end
end

describe "Redis total operation deadline" do
  it "includes auth/select setup and returns pool capacity after failure" do
    listener = TCPServer.new("127.0.0.1", 0)
    accepted = Atomic(Int32).new(0)
    done = Channel(Nil).new(1)
    spawn do
      while socket = listener.accept?
        number = accepted.add(1)
        begin
          socket.read_timeout = 1.second
          while command = read_redis_request(socket)
            sleep 40.milliseconds if number == 0
            socket << (command.first == "PING" ? "+PONG\r\n" : "+OK\r\n")
            socket.flush
          end
        rescue IO::Error
        ensure
          socket.close
        end
      end
    ensure
      done.send(nil)
    end
    store = JoobQ::RedisStore.new(url: "redis://user:secret@127.0.0.1:#{listener.local_address.port}/1",
      pool_size: 1, connect_timeout: 1.second, command_timeout: 1.second, operation_timeout: 60.milliseconds)
    started = Time.instant
    expect_raises(Redis::Error) { store.redis.ping }
    (Time.instant - started).should be < 250.milliseconds
    sleep 60.milliseconds
    store.redis.ping.should eq("PONG")
  ensure
    store.try(&.close)
    listener.try(&.close)
    if done
      select
      when done.receive
      when timeout(2.seconds)
        fail "fake Redis did not stop"
      end
    end
  end

  it "bounds a reply that drips bytes within each per-read timeout" do
    listener = TCPServer.new("127.0.0.1", 0)
    done = Channel(Nil).new(1)
    spawn do
      if socket = listener.accept?
        begin
          read_redis_request(socket)
          "+PONG\r\n".each_char do |char|
            sleep 25.milliseconds
            socket << char
            socket.flush
          end
        rescue IO::Error
        ensure
          socket.close
        end
      end
    ensure
      done.send(nil)
    end
    store = JoobQ::RedisStore.new(host: "127.0.0.1", port: listener.local_address.port,
      command_timeout: 1.second, operation_timeout: 60.milliseconds)
    started = Time.instant
    expect_raises(JoobQ::RedisOutcomeUnknown) { store.redis.ping }
    (Time.instant - started).should be < 200.milliseconds
  ensure
    store.try(&.close)
    listener.try(&.close)
    if done
      select
      when done.receive
      when timeout(2.seconds)
        fail "fake Redis did not stop"
      end
    end
  end
end
