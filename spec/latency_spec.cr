require "./spec_helper"

module JoobQ
  describe Latency do
    redis = -> { JoobQ.store.as(RedisStore).redis }

    queue = "lat-#{Random::Secure.hex(4)}" # nothing else counts under this name

    before_each do
      Latency.stop
      Latency.reset
      redis.call.del(Latency::KEY)
    end

    describe ".bucket" do
      it "puts a duration in the first bucket whose upper bound covers it" do
        [0.0002, 0.001, 0.0011, 0.05, 0.9, 1.0, 1.01, 37.0, 599.0, 700.0].each do |seconds|
          bucket = Latency.bucket(seconds)
          Latency.upper_seconds(bucket).should be >= seconds - 1e-9
          Latency.upper_seconds(bucket - 1).should be < seconds if bucket > 0
        end
      end

      it "has a first and a last bucket, and one for anything slower" do
        Latency.bucket(0.0).should eq(0)
        Latency.bucket(-1.0).should eq(0)
        Latency.bucket(0.001).should eq(0)
        Latency.bucket(0.0011).should eq(1)
        Latency.bucket(749.0).should eq(Latency::LAST_BUCKET)
        Latency.bucket(750.0).should eq(Latency::OVERFLOW)
        Latency.bucket(1e9).should eq(Latency::OVERFLOW)
      end

      it "is within about 33 % at the upper bound and 15 % at the middle of its bucket" do
        [0.003, 0.07, 1.3, 42.0].each do |seconds|
          bucket = Latency.bucket(seconds)
          (Latency.upper_seconds(bucket) / seconds).should be_close(1.0, 0.34)
          (Latency.middle_seconds(bucket) / seconds).should be_close(1.0, 0.16)
        end
      end
    end

    describe ".flush and .read" do
      it "adds what this process counted to a shared, cumulative hash" do
        3.times { Latency.observe(queue, 0.5) }
        Latency.observe("#{queue}-other", 0.002)
        Latency.flush(redis.call)

        Latency.read(redis.call)[queue][Latency.bucket(0.5)].should eq(3)
        Latency.read(redis.call)["#{queue}-other"][Latency.bucket(0.002)].should eq(1)

        2.times { Latency.observe(queue, 0.5) }
        Latency.flush(redis.call)
        Latency.read(redis.call)[queue][Latency.bucket(0.5)].should eq(5)
      end

      it "does not count the same executions twice" do
        Latency.observe(queue, 0.5)
        Latency.flush(redis.call)
        Latency.flush(redis.call)

        Latency.read(redis.call)[queue].sum.should eq(1)
      end

      it "loses nothing when many fibers count at once" do
        done = Channel(Nil).new
        8.times do
          spawn do
            1000.times { |i| Latency.observe(queue, (i % 10) * 0.01) }
            done.send(nil)
          end
        end
        8.times { done.receive }
        Latency.flush(redis.call)

        Latency.read(redis.call)[queue].sum.should eq(8000)
      end

      it "keeps the counts for the next try when Redis cannot be reached" do
        Latency.observe(queue, 0.5)
        unreachable = Redis::PooledClient.new(host: "localhost", port: 1, pool_size: 1, pool_timeout: 0.2)

        expect_raises(Exception) { Latency.flush(unreachable) }
        Latency.flush(redis.call)

        Latency.read(redis.call)[queue].sum.should eq(1)
      end

      it "ignores fields it does not understand" do
        redis.call.hset(Latency::KEY, "example|9999", 5)
        redis.call.hset(Latency::KEY, "garbage", 5)

        Latency.read(redis.call).should be_empty
      end
    end

    describe "in a worker" do
      recorded = ->(name : String) do
        Latency.flush(redis.call)
        Latency.read(redis.call)[name]?.try(&.sum) || 0_i64
      end

      it "records how long a job's perform took" do
        job_queue = Queue(ExampleJob | FailJob).new("example", 1)
        worker = Worker(ExampleJob | FailJob).new(1, Channel(Nil).new, job_queue)
        JoobQ.add ExampleJob.new(1)

        worker.run
        eventually(5.seconds) { recorded.call("example") >= 1 }.should be_true
        worker.terminate
      end

      it "records it for a job that fails, too" do
        job_queue = Queue(ExampleJob | FailJob).new("failed", 1)
        worker = Worker(ExampleJob | FailJob).new(1, Channel(Nil).new, job_queue)
        failing = FailJob.new
        failing.retries = 0
        JoobQ.add failing

        worker.run
        eventually(5.seconds) { recorded.call("failed") >= 1 }.should be_true
        worker.terminate
      end
    end
  end
end
