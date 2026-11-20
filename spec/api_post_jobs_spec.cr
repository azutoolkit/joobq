require "./spec_helper"

module JoobQ
  describe "POST /joobq/jobs" do
    post_jobs = ->(body : String) do
      io = IO::Memory.new
      request = HTTP::Request.new("POST", "/joobq/jobs", HTTP::Headers{"Content-Type" => "application/json"}, body)
      context = HTTP::Server::Context.new(request, HTTP::Server::Response.new(io))
      handler = APIHandler.new(unsafe_no_auth: true)
      handler.next = ->(_ctx : HTTP::Server::Context) { }
      handler.call(context)
      context.response.close
      io.rewind
      parsed = HTTP::Client::Response.from_io(io)
      {parsed.status_code, JSON.parse(parsed.body)}
    end

    before_each do
      JoobQ.reset
    end

    it "hands the job its arguments unchanged, markup characters included" do
      status, body = post_jobs.call(%({"queue":"factory_test","job_type":"FactoryTestJob","data":{"data":"a & b <i> \\"q\\""}}))

      status.should eq(201)
      stored = JoobQ.store.as(RedisStore).dequeue("factory_test", FactoryTestJob).not_nil!
      job = FactoryTestJob.from_json(stored)
      job.data.should eq(%(a & b <i> "q"))
      body["job_id"].as_s.should eq(job.jid.to_s)
      body["job_id"].as_s.should_not be_empty
    end

    it "answers 422 and enqueues nothing when the data does not fit the job class" do
      status, body = post_jobs.call(%({"queue":"example","job_type":"ExampleJob","data":{"x":"not a number"}}))

      status.should eq(422)
      body["error"].as_s.should_not be_empty
      JoobQ.store.as(RedisStore).queue_size("example").should eq(0)
    end

    it "answers 422 and enqueues nothing when a required argument is missing" do
      status, _ = post_jobs.call(%({"queue":"example","job_type":"ExampleJob","data":{}}))

      status.should eq(422)
      JoobQ.store.as(RedisStore).queue_size("example").should eq(0)
    end

    it "answers 422 when job_type is not the queue's job class" do
      status, body = post_jobs.call(%({"queue":"example","job_type":"Job1","data":{"x":1}}))

      status.should eq(422)
      body.to_json.should contain("ExampleJob")
      JoobQ.store.as(RedisStore).queue_size("example").should eq(0)
    end

    it "keeps the job off the queue until its delay has passed" do
      status, body = post_jobs.call(%({"queue":"example","job_type":"ExampleJob","data":{"x":1},"delay":60}))

      status.should eq(201)
      body["job_id"].as_s.should_not be_empty
      JoobQ.store.as(RedisStore).queue_size("example").should eq(0)
      JoobQ.store.set_size(RedisStore::DELAYED_SET).should eq(1)
    end

    it "gives the job the retries of the request" do
      post_jobs.call(%({"queue":"example","job_type":"ExampleJob","data":{"x":1},"retries":7}))[0].should eq(201)

      stored = JoobQ.store.as(RedisStore).dequeue("example", ExampleJob).not_nil!
      ExampleJob.from_json(stored).retries.should eq(7)
    end

    it "lands the job on the queue named in the request" do
      post_jobs.call(%({"queue":"example","job_type":"ExampleJob","data":{"x":1,"queue":"elsewhere"}}))[0].should eq(201)

      JoobQ.store.as(RedisStore).queue_size("example").should eq(1)
      JoobQ.store.as(RedisStore).queue_size("elsewhere").should eq(0)
    end
  end
end
