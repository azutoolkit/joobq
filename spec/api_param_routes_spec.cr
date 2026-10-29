require "./spec_helper"

module JoobQ
  describe APIHandler do
    dispatch = ->(method : String, path : String) do
      io = IO::Memory.new
      context = HTTP::Server::Context.new(HTTP::Request.new(method, path), HTTP::Server::Response.new(io))
      fell_through = false
      handler = APIHandler.new
      handler.next = ->(_ctx : HTTP::Server::Context) { fell_through = true }
      handler.call(context)
      context.response.flush
      {context.response.status_code, fell_through}
    end

    it "routes paths matching a ':param' pattern to their handler" do
      status, fell_through = dispatch.call("POST", "/joobq/jobs/#{UUID.random}/retry")

      fell_through.should be_false
      status.should eq(404) # handler ran and found no such job
    end

    it "does not match a different method or a different segment count" do
      dispatch.call("GET", "/joobq/jobs/#{UUID.random}/retry")[1].should be_true
      dispatch.call("POST", "/joobq/jobs/#{UUID.random}")[1].should be_true
    end

    it "still prefers exact routes over parametrised ones" do
      dispatch.call("GET", "/joobq/jobs/retrying")[1].should be_false
    end

    it "redrives a dead job through the retry endpoint" do
      store = JoobQ.store.as(RedisStore)
      job = ExampleJob.new(5)
      job.dead!
      store.redis.zadd(DeadLetterQueue::KEY, 1000_i64, job.to_json)

      status, _ = dispatch.call("POST", "/joobq/jobs/#{job.jid}/retry")

      status.should eq(200)
      store.redis.zcard(DeadLetterQueue::KEY).should eq(0)
      store.queue_size("example").should eq(1)
    end

    it "answers 404 for an unknown job" do
      dispatch.call("POST", "/joobq/jobs/#{UUID.random}/retry")[0].should eq(404)
    end
  end
end

module JoobQ
  describe "POST /joobq/jobs deprecation" do
    # This route enqueues without authentication; its replacement is JoobQ.enqueue behind an authenticated API.
    post_jobs = ->(body : String) do
      io = IO::Memory.new
      request = HTTP::Request.new("POST", "/joobq/jobs", HTTP::Headers{"Content-Type" => "application/json"}, body)
      context = HTTP::Server::Context.new(request, HTTP::Server::Response.new(io))
      handler = APIHandler.new
      handler.next = ->(_ctx : HTTP::Server::Context) { }
      handler.call(context)
      context.response.flush
      context.response
    end

    it "marks a successful response as deprecated" do
      JoobQ["example"].clear

      response = post_jobs.call(%({"queue":"example","job_type":"ExampleJob","data":{"x":1}}))

      response.headers["Deprecation"]?.should eq("true")
    end

    it "marks a rejected request as deprecated too" do
      response = post_jobs.call("not json")

      response.status_code.should eq(400)
      response.headers["Deprecation"]?.should eq("true")
    end
  end
end
