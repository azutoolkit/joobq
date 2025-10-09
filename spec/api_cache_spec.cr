require "./spec_helper"

module JoobQ
  describe APICache do
    before_each do
      # Clear cache before each test
      APICache.instance.clear_all
    end

    describe "caching behavior" do
      it "caches data with TTL" do
        cache = APICache.instance

        call_count = 0
        result = cache.get_processing_jobs(100) do
          call_count += 1
          ["job1", "job2"]
        end

        result.should eq(["job1", "job2"])
        call_count.should eq(1)

        # Second call should hit cache
        result2 = cache.get_processing_jobs(100) do
          call_count += 1
          ["job3", "job4"]
        end

        result2.should eq(["job1", "job2"]) # Cached value
        call_count.should eq(1)             # Block not called again
      end

      it "expires cached data after TTL" do
        cache = APICache.instance

        call_count = 0
        result1 = cache.get_processing_jobs(100) do
          call_count += 1
          ["job1"]
        end

        # Wait for TTL to expire (PROCESSING_JOBS_TTL = 2 seconds)
        sleep 2.1.seconds

        result2 = cache.get_processing_jobs(100) do
          call_count += 1
          ["job2"]
        end

        result2.should eq(["job2"]) # Fresh value
        call_count.should eq(2)     # Block called twice
      end

      it "handles cache invalidation" do
        cache = APICache.instance

        call_count = 0
        cache.get_dead_jobs(50) do
          call_count += 1
          ["dead1"]
        end

        # Invalidate cache
        cache.invalidate_dead_jobs

        # Should fetch fresh data
        cache.get_dead_jobs(50) do
          call_count += 1
          ["dead2"]
        end

        call_count.should eq(2)
      end
    end

    describe "thread safety" do
      pending "handles concurrent cache access" do
        cache = APICache.instance
        results = [] of Array(String)

        # Simulate concurrent access
        channel = Channel(Array(String)).new
        10.times do
          spawn do
            result = cache.get_processing_jobs(100) do
              ["concurrent_job"]
            end
            channel.send(result)
          end
        end

        # Collect results
        10.times { results << channel.receive }

        # All results should be the same (cached)
        results.uniq.size.should eq(1)
      end
    end

    describe "cache statistics" do
      it "returns cache stats" do
        cache = APICache.instance

        # Add some cached data
        cache.get_error_stats { {"error:example" => 5} }

        stats = cache.stats
        stats[:error_stats][:cached].should be_true
        stats[:error_stats][:expired].should be_false
        stats[:processing_jobs][:cached].should be_false
      end
    end

    describe "specific cache types" do
      it "caches processing jobs" do
        cache = APICache.instance
        result = cache.get_processing_jobs(100) { ["job1"] }
        result.should eq(["job1"])
      end

      it "caches delayed jobs" do
        cache = APICache.instance
        result = cache.get_delayed_jobs(1000) { ["delayed1"] }
        result.should eq(["delayed1"])
      end

      it "caches dead jobs" do
        cache = APICache.instance
        result = cache.get_dead_jobs(50) { ["dead1"] }
        result.should eq(["dead1"])
      end

      it "caches error stats" do
        cache = APICache.instance
        result = cache.get_error_stats { {"test" => 1} }
        result.should eq({"test" => 1})
      end

      it "caches recent errors" do
        cache = APICache.instance
        error = ErrorContext.new(
          job_id: "test",
          queue_name: "test",
          worker_id: "test",
          job_type: "Test",
          error_type: "test",
          error_message: "test",
          error_class: "Test",
          backtrace: ["test"],
          retry_count: 0
        )
        result = cache.get_recent_errors(20) { [error] }
        result.size.should eq(1)
      end
    end

    describe "cache clearing" do
      it "clears all caches" do
        cache = APICache.instance

        # Populate caches
        cache.get_processing_jobs(100) { ["job1"] }
        cache.get_dead_jobs(50) { ["dead1"] }
        cache.get_error_stats { {"test" => 1} }

        # Clear all
        cache.clear_all

        # All caches should be empty
        stats = cache.stats
        stats.values.all? { |v| !v[:cached] }.should be_true
      end

      it "clears individual caches" do
        cache = APICache.instance

        cache.get_processing_jobs(100) { ["job1"] }
        cache.invalidate_processing_jobs

        stats = cache.stats
        stats[:processing_jobs][:cached].should be_false
      end
    end
  end
end

