require "./spec_helper"

module JoobQ
  describe Statistics do
    stats = Statistics.instance
    key = "example"

    before_each do
      JoobQ.reset
    end

    it "creates stats key" do
      stats.create_key(key).should eq "Ok!"
    end

    context "count" do
      it "gets queues and sets totals" do
        stats.totals.size.should eq 10
      end
    end

    context "querying" do
      it "queries and perform aggregations (avg, sum, count)" do
        from = 1.day.ago.to_unix_ms

        10.times do |i|
          sleep 10.milliseconds
        end

        to = 10.milliseconds.from_now.to_unix_ms

        results = stats.range(key, from, to, aggr: "count", group: 100)
        results.as(Array).size.should be <= 100
      end
    end
  end
end
