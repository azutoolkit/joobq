require "./spec_helper"

module JoobQ
  describe Statistics do
    stats = Statistics.instance

    before_each do
      JoobQ.reset
      stats.reset
    end

    it "creates stats key" do
      stats.create_key.should eq "OK"
    end

    it "records a stat for worker" do
      stats.create_key

      result = stats.track "example", 1, 1
      result.as(Int64).should be > 0.to_i64
    end

    it "gets count of failed jobs" do
      stats.redis.flushall

      stats.failed("Failed").size.should eq 0
      Failed.add(FailJob.new, Exception.new)

      stats.failed("*Failed*").size.should eq 1
    end

    context "count" do
      it "gets queues and sets totals" do
        stats.count_stats.size.should eq 13
      end
    end

    context "querying" do
      it "queries and perform aggregations (avg, sum, count)" do
        stats.reset
        stats.create_key

        from = 1.day.ago.to_unix_ms

        10.times do |i|
          sleep 10.milliseconds
          stats.track "example", i, rand(5)
        end

        to = 10.milliseconds.from_now.to_unix_ms

        results = stats.query(from, to, "name=example", aggr: "count", group_by: 100)
        results.as(Array).size.should be <= 100
      end
    end
  end
end
