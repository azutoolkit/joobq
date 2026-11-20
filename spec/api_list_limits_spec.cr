require "./spec_helper"

module JoobQ
  describe "management API list limits" do
    get = ->(path : String) do
      io = IO::Memory.new
      context = HTTP::Server::Context.new(HTTP::Request.new("GET", path), HTTP::Server::Response.new(io))
      handler = APIHandler.new(unsafe_no_auth: true)
      handler.next = ->(_ctx : HTTP::Server::Context) { }
      handler.call(context)
      context.response.close
      io.rewind
      parsed = HTTP::Client::Response.from_io(io)
      {parsed.status_code, parsed.body}
    end

    before_each do
      JoobQ.reset
    end

    {"/joobq/jobs/retrying", "/joobq/jobs/dead", "/joobq/errors/recent"}.each do |path|
      describe "GET #{path}" do
        it "answers 400 for a limit that is not an integer" do
          status, body = get.call("#{path}?limit=abc")

          status.should eq(400)
          body.should contain("Limit must be a valid integer")
        end

        it "answers 400 for a negative or zero limit" do
          get.call("#{path}?limit=-1")[0].should eq(400)
          get.call("#{path}?limit=0")[0].should eq(400)
        end

        it "answers 400 for a limit above the documented maximum" do
          status, body = get.call("#{path}?limit=1000000")

          status.should eq(400)
          body.should contain("Limit must be between 1 and #{APIValidation::MAX_LIST_LIMIT}")
        end

        it "accepts the maximum and the default" do
          get.call("#{path}?limit=#{APIValidation::MAX_LIST_LIMIT}")[0].should eq(200)
          get.call(path)[0].should eq(200)
        end
      end
    end

    it "never returns more than the maximum, even with more jobs stored" do
      store = JoobQ.store.as(RedisStore)
      (APIValidation::MAX_LIST_LIMIT + 20).times do |i|
        job = ExampleJob.new(i)
        job.dead!
        store.redis.zadd(DeadLetterQueue::KEY, i.to_i64, job.to_json)
      end

      status, body = get.call("/joobq/jobs/dead?limit=#{APIValidation::MAX_LIST_LIMIT}")

      status.should eq(200)
      JSON.parse(body)["jobs"].as_a.size.should eq(APIValidation::MAX_LIST_LIMIT)
    end
  end
end
