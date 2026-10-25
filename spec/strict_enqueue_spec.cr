require "./spec_helper"

module JoobQ
  # The strict by-name enqueue path: unlike Queue#add, which logs and swallows bad payloads, these raise.
  describe "strict enqueue" do
    describe "Queue#add!" do
      it "enqueues a valid payload and returns its jid" do
        queue = JoobQ["example"]
        queue.clear
        job = ExampleJob.new(7)

        queue.add!(job.to_json).should eq(job.jid.to_s)

        queue.size.should eq(1)
      end

      it "raises on unparseable JSON and enqueues nothing" do
        queue = JoobQ["example"]
        queue.clear

        expect_raises(JSON::ParseException) { queue.add!("not json") }

        queue.size.should eq(0)
      end

      it "raises on JSON of the wrong shape and enqueues nothing" do
        queue = JoobQ["example"]
        queue.clear

        expect_raises(JSON::SerializableError) { queue.add!(%({"x": "not an int"})) }

        queue.size.should eq(0)
      end

      it "enqueues onto its own queue even when the payload names another key" do
        queue = JoobQ["example"]
        queue.clear
        redis = JoobQ.store.as(RedisStore).redis
        redis.del("joobq:processing:example", "other_key")
        job = ExampleJob.new(1)
        job.queue = "joobq:processing:example"

        queue.add!(job.to_json).should eq(job.jid.to_s)

        queue.size.should eq(1)
        redis.llen("joobq:processing:example").should eq(0)
        redis.exists("other_key").should eq(0)
      end

      it "enqueues onto a non-default queue when the payload names no queue" do
        queue = JoobQ["failed"]
        queue.clear
        JoobQ["example"].clear

        queue.add!(%({})).should_not be_empty

        queue.size.should eq(1)
        JoobQ["example"].size.should eq(0)
      end

      it "leaves Queue#add swallowing bad payloads" do
        queue = JoobQ["example"]
        queue.clear

        queue.add("not json").should be_nil
      end
    end

    describe "Queue#add_delayed" do
      it "schedules the job in the delayed set at the given time and returns its jid" do
        queue = JoobQ["example"]
        queue.clear
        redis = JoobQ.store.as(RedisStore).redis
        redis.del(RedisStore::DELAYED_SET)
        job = ExampleJob.new(5)
        at = Time.utc + 10.minutes

        queue.add_delayed(job.to_json, at).should eq(job.jid.to_s)

        queue.size.should eq(0)
        redis.zcard(RedisStore::DELAYED_SET).should eq(1)
        member = redis.zrange(RedisStore::DELAYED_SET, 0, -1, with_scores: true)
        JSON.parse(member[0].as(String))["jid"].as_s.should eq(job.jid.to_s)
        member[1].as(String).to_i64.should eq(at.to_unix_ms)
        redis.del(RedisStore::DELAYED_SET)
      end

      it "schedules onto its own queue even when the payload names another key" do
        queue = JoobQ["example"]
        redis = JoobQ.store.as(RedisStore).redis
        redis.del(RedisStore::DELAYED_SET)
        job = ExampleJob.new(1)
        job.queue = "joobq:processing:example"

        queue.add_delayed(job.to_json, Time.utc + 10.minutes)

        member = redis.zrange(RedisStore::DELAYED_SET, 0, 0).first.as(String)
        JSON.parse(member)["queue"].as_s.should eq("example")
        redis.del(RedisStore::DELAYED_SET)
      end

      it "raises on a bad payload and schedules nothing" do
        queue = JoobQ["example"]
        JoobQ.store.as(RedisStore).redis.del(RedisStore::DELAYED_SET)

        expect_raises(JSON::ParseException) { queue.add_delayed("not json", Time.utc + 1.minute) }

        JoobQ.store.as(RedisStore).redis.zcard(RedisStore::DELAYED_SET).should eq(0)
      end
    end

    describe "JoobQ.enqueue" do
      it "enqueues onto the named queue and returns the jid" do
        JoobQ["example"].clear
        job = ExampleJob.new(3)

        JoobQ.enqueue("example", job.to_json).should eq(job.jid.to_s)

        JoobQ["example"].size.should eq(1)
      end

      it "raises UnknownQueue for a queue that is not registered, naming it" do
        error = expect_raises(JoobQ::UnknownQueue) { JoobQ.enqueue("no_such_queue", "{}") }

        error.message.to_s.should contain("no_such_queue")
        error.queue_name.should eq("no_such_queue")
      end

      it "keeps control characters and length out of the UnknownQueue message" do
        error = expect_raises(JoobQ::UnknownQueue) { JoobQ.enqueue("bad\nname" + "x" * 500, "{}") }

        error.message.to_s.should_not contain("\n")
        error.message.to_s.size.should be < 200
      end

      it "raises on a bad payload and enqueues nothing" do
        JoobQ["example"].clear

        expect_raises(JSON::ParseException) { JoobQ.enqueue("example", "not json") }

        JoobQ["example"].size.should eq(0)
      end
    end
  end
end
