require "./spec_helper"

describe JoobQ::RedisPipeline do
  it "uses a single connection for actual batched commands and reports their results" do
    store = JoobQ::RedisStore.new(pool_size: 1, pool_timeout: 0.1)
    batch = [
      ->(pipe : Redis::PipelineApi) { pipe.set("pipeline_spec", "value"); nil },
      ->(pipe : Redis::PipelineApi) { pipe.get("pipeline_spec"); nil },
    ]
    store.pipeline.execute_batch(batch).should eq(["OK", "value"])
    expect_raises(Redis::Error) do
      store.pipeline.execute_batch([
        ->(pipe : Redis::PipelineApi) { pipe.lpush("pipeline_spec", "bad"); nil },
        ->(pipe : Redis::PipelineApi) { pipe.get("pipeline_spec"); nil },
      ])
    end
    store.redis.ping.should eq("PONG")
  ensure
    store.try(&.close)
  end

  it "counts concurrent batches without losing updates or dividing by zero" do
    JoobQ::RedisPipeline.reset_pipeline_stats
    pipeline = JoobQ.store.as(JoobQ::RedisStore).pipeline
    done = Channel(Nil).new(100)
    100.times do
      spawn do
        pipeline.track_pipeline_operation(10, true)
        done.send(nil)
      end
    end
    100.times { done.receive }
    stats = JoobQ::RedisPipeline.pipeline_stats
    stats.total_pipeline_calls.should eq(100)
    stats.total_commands_batched.should eq(1000)
    stats.average_batch_size.should eq(10.0)
  end
end
