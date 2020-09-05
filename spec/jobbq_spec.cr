require "./spec_helper"

describe JoobQ do
  describe "#register" do
    it "registers a queue" do
      JoobQ.queues.size.should eq 2
    end

    it "gets queue by name" do
      JoobQ["example"].should be_a JoobQ::Queue(ExampleJob | FailJob)
      JoobQ["single"].should be_a JoobQ::Queue(Job1)
    end
  end
end
