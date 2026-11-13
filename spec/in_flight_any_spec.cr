require "./spec_helper"

module JoobQ
  describe InFlight do
    before_each { InFlight.clear }
    after_each { InFlight.clear }

    it "any? is true while a claim for the queue exists and false for other queues and after it finished" do
      InFlight.any?("some_queue").should be_false

      token = InFlight.claimed("some_queue", ["{}"]).first
      InFlight.any?("some_queue").should be_true
      InFlight.any?("other_queue").should be_false

      InFlight.finished(token)
      InFlight.any?("some_queue").should be_false
    end

    it "any? ignores a claim shutdown abandoned" do
      InFlight.claimed("some_queue", ["{}"])
      InFlight.abandon_all
      InFlight.any?("some_queue").should be_false
    end
  end
end
