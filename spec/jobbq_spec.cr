require "./spec_helper"

describe JoobQ do
  describe "#register" do
    it "registers a queue" do
      JoobQ.queues.size.should eq 5
    end

    it "gets queue by name" do
      JoobQ["joobq_queue1"].should be_a JoobQ::Queue(ExampleJob)
      JoobQ["joobq_queue2"].should be_a JoobQ::Queue(FailJob)
      JoobQ["joobq_queue3"].should be_a JoobQ::Queue(ExampleJob | FailJob)
    end
  end
end
