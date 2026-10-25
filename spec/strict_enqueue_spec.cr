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

      it "leaves Queue#add swallowing bad payloads" do
        queue = JoobQ["example"]
        queue.clear

        queue.add("not json").should be_nil
      end
    end
  end
end
