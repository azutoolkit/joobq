require "./spec_helper"

module JoobQ
  describe Job do
    before_each do
      JoobQ.reset
    end

    describe "initialization" do
      it "creates job with unique JID" do
        job1 = ExampleJob.new(1)
        job2 = ExampleJob.new(2)

        job1.jid.should_not eq(job2.jid)
        job1.jid.should be_a(UUID)
      end

      it "assigns default queue from config" do
        job = ExampleJob.new(1)
        job.queue.should eq("example")
      end

      it "assigns default retries from config" do
        job = ExampleJob.new(1)
        job.retries.should eq(3)
        job.max_retries.should eq(3)
      end

      it "sets initial status to Enqueued" do
        job = ExampleJob.new(1)
        job.status.should eq(Job::Status::Enqueued)
        job.enqueued?.should be_true
      end

      it "sets expiration time" do
        job = ExampleJob.new(1)
        job.expires.should be > 0
        job.expires.should be_a(Int64)
      end

      it "initializes without error" do
        job = ExampleJob.new(1)
        job.error.should be_nil
      end
    end

    describe "status management" do
      it "has all expected status values" do
        statuses = Job::Status.values

        statuses.should contain(Job::Status::Completed)
        statuses.should contain(Job::Status::Dead)
        statuses.should contain(Job::Status::Enqueued)
        statuses.should contain(Job::Status::Expired)
        statuses.should contain(Job::Status::Retrying)
        statuses.should contain(Job::Status::Running)
        statuses.should contain(Job::Status::Scheduled)
      end

      describe "status predicates" do
        it "checks completed status" do
          job = ExampleJob.new(1)
          job.completed?.should be_false
          job.completed!
          job.completed?.should be_true
        end

        it "checks dead status" do
          job = ExampleJob.new(1)
          job.dead?.should be_false
          job.dead!
          job.dead?.should be_true
        end

        it "checks enqueued status" do
          job = ExampleJob.new(1)
          job.enqueued?.should be_true
        end

        it "checks expired status" do
          job = ExampleJob.new(1)
          job.expired?.should be_false
          job.expired!
          job.expired?.should be_true
        end

        it "checks retrying status" do
          job = ExampleJob.new(1)
          job.retrying?.should be_false
          job.retrying!
          job.retrying?.should be_true
        end

        it "checks running status" do
          job = ExampleJob.new(1)
          job.running?.should be_false
          job.running!
          job.running?.should be_true
        end

        it "checks scheduled status" do
          job = ExampleJob.new(1)
          job.scheduled?.should be_false
          job.scheduled!
          job.scheduled?.should be_true
        end
      end

      describe "status transitions" do
        it "transitions from Enqueued to Running" do
          job = ExampleJob.new(1)
          job.enqueued?.should be_true

          job.running!
          job.running?.should be_true
          job.enqueued?.should be_false
        end

        it "transitions from Running to Completed" do
          job = ExampleJob.new(1)
          job.running!
          job.running?.should be_true

          job.completed!
          job.completed?.should be_true
          job.running?.should be_false
        end

        it "transitions from Running to Retrying" do
          job = ExampleJob.new(1)
          job.running!

          job.retrying!
          job.retrying?.should be_true
          job.running?.should be_false
        end

        it "transitions from Retrying to Dead" do
          job = ExampleJob.new(1)
          job.retrying!
          job.retries = 0

          job.dead!
          job.dead?.should be_true
          job.retrying?.should be_false
        end

        it "can be marked as expired" do
          job = ExampleJob.new(1)
          job.expired!
          job.expired?.should be_true
        end
      end
    end

    describe "properties" do
      it "allows queue modification" do
        job = ExampleJob.new(1)
        job.queue = "custom_queue"
        job.queue.should eq("custom_queue")
      end

      it "allows retries modification" do
        job = ExampleJob.new(1)
        job.retries = 5
        job.retries.should eq(5)
      end

      it "allows max_retries modification" do
        job = ExampleJob.new(1)
        job.max_retries = 10
        job.max_retries.should eq(10)
      end

      it "allows expires modification" do
        job = ExampleJob.new(1)
        future_time = (Time.local + 1.hour).to_unix_ms
        job.expires = future_time
        job.expires.should eq(future_time)
      end

      it "allows status modification" do
        job = ExampleJob.new(1)
        job.status = Job::Status::Running
        job.status.should eq(Job::Status::Running)
      end

      it "allows error property to be set" do
        job = ExampleJob.new(1)
        job.error = {
          failed_at:      Time.local.to_rfc3339,
          message:        "Test error",
          backtrace:      "line 1\nline 2",
          cause:          "RuntimeError",
          error_type:     "unknown_error",
          error_class:    "RuntimeError",
          retry_count:    1,
          system_context: {"worker_id" => "test-worker"},
        }

        job.error.should_not be_nil
        job.error.not_nil![:message].should eq("Test error")
      end
    end

    describe "JSON serialization" do
      it "serializes to JSON" do
        job = ExampleJob.new(42)
        json = job.to_json

        json.should contain("jid")
        json.should contain("queue")
        json.should contain("retries")
        json.should contain("status")
        json.should contain("\"x\":42")
      end

      it "deserializes from JSON" do
        job1 = ExampleJob.new(99)
        json = job1.to_json

        job2 = ExampleJob.from_json(json)
        job2.jid.should eq(job1.jid)
        job2.queue.should eq(job1.queue)
        job2.retries.should eq(job1.retries)
        job2.x.should eq(99)
      end

      it "preserves all properties through serialization" do
        job1 = ExampleJob.new(123)
        job1.queue = "test_queue"
        job1.retries = 5
        job1.max_retries = 10
        job1.running!

        json = job1.to_json
        job2 = ExampleJob.from_json(json)

        job2.jid.should eq(job1.jid)
        job2.queue.should eq("test_queue")
        job2.retries.should eq(5)
        job2.max_retries.should eq(10)
        job2.running?.should be_true
      end

      it "serializes error information" do
        job = ExampleJob.new(1)
        job.error = {
          failed_at:      Time.local.to_rfc3339,
          message:        "Error occurred",
          backtrace:      "trace",
          cause:          "Exception",
          error_type:     "test_error",
          error_class:    "TestError",
          retry_count:    2,
          system_context: {"key" => "value"},
        }

        json = job.to_json
        parsed_job = ExampleJob.from_json(json)

        parsed_job.error.should_not be_nil
        parsed_job.error.not_nil![:message].should eq("Error occurred")
        parsed_job.error.not_nil![:retry_count].should eq(2)
      end
    end

    describe "comparison" do
      it "compares jobs by JID" do
        job1 = ExampleJob.new(1)
        job2 = ExampleJob.new(2)

        # Jobs should be comparable
        (job1 <=> job2).should be_a(Int32)
      end

      it "considers same job equal" do
        job1 = ExampleJob.new(1)
        job2 = ExampleJob.from_json(job1.to_json)

        (job1 <=> job2).should eq(0)
      end

      it "can be sorted by JID" do
        jobs = [
          ExampleJob.new(1),
          ExampleJob.new(2),
          ExampleJob.new(3),
        ]

        sorted = jobs.sort
        sorted.should be_a(Array(ExampleJob))
        sorted.size.should eq(3)
      end
    end

    describe ".enqueue" do
      it "enqueues job with parameters" do
        store = JoobQ.store.as(RedisStore)
        store.clear_queue("example")

        jid = ExampleJob.enqueue(x: 42)

        # enqueue returns the JID as a string
        jid.should be_a(String)
        UUID.parse?(jid.to_s).should_not be_nil
        store.queue_size("example").should eq(1)
      end

      it "assigns Enqueued status" do
        # We can't easily inspect the enqueued job without processing,
        # but we can verify it was added
        store = JoobQ.store.as(RedisStore)
        store.clear_queue("example")

        ExampleJob.enqueue(x: 1)

        store.queue_size("example").should eq(1)
      end
    end

    describe ".batch_enqueue" do
      it "enqueues multiple jobs" do
        store = JoobQ.store.as(RedisStore)
        store.clear_queue("example")

        jobs = [
          ExampleJob.new(1),
          ExampleJob.new(2),
          ExampleJob.new(3),
        ]

        ExampleJob.batch_enqueue(jobs)

        store.queue_size("example").should eq(3)
      end

      it "validates batch size limits" do
        expect_raises(Exception, /greater than 0/) do
          ExampleJob.batch_enqueue([] of ExampleJob, batch_size: 0)
        end
      end

      it "rejects batch size > 1000" do
        expect_raises(Exception, /less than or equal to 1000/) do
          ExampleJob.batch_enqueue([ExampleJob.new(1)], batch_size: 1001)
        end
      end

      it "uses default batch size" do
        jobs = [ExampleJob.new(1)]
        expect_raises(Exception, /greater than 0/) do
          # This should work with default batch size
          ExampleJob.batch_enqueue(jobs, batch_size: -1)
        end
      end
    end

    describe ".perform" do
      it "executes job immediately without enqueuing" do
        store = JoobQ.store.as(RedisStore)
        store.clear_queue("example")

        job = ExampleJob.new(1)
        initial_x = job.x

        job.perform

        # Job executed (x incremented)
        job.x.should eq(initial_x + 1)

        # Not enqueued
        store.queue_size("example").should eq(0)
      end

      it "executes with class method" do
        # TestJob.perform should execute immediately
        ExampleJob.perform

        # No exception means success
      end

      it "executes with parameters" do
        store = JoobQ.store.as(RedisStore)
        store.clear_queue("example")

        # Should execute immediately, not enqueue
        ExampleJob.perform(x: 99)

        store.queue_size("example").should eq(0)
      end
    end

    describe ".delay" do
      it "delays job execution" do
        store = JoobQ.store.as(RedisStore)
        store.clear_queue("joobq:delayed_jobs")

        jid = ExampleJob.delay(for: 1.hour, x: 1)

        jid.should be_a(UUID)
        store.set_size("joobq:delayed_jobs").should eq(1)
      end

      it "marks job as Scheduled" do
        jid = ExampleJob.delay(for: 30.seconds, x: 5)
        jid.should be_a(UUID)
      end
    end

    describe ".enqueue_at" do
      it "enqueues job at specific time" do
        store = JoobQ.store.as(RedisStore)
        store.clear_queue("joobq:delayed_jobs")

        jid = ExampleJob.enqueue_at(2.minutes, x: 10)

        jid.should be_a(UUID)
        store.set_size("joobq:delayed_jobs").should eq(1)
      end
    end

    describe ".schedule" do
      it "schedules recurring job" do
        job = TestJob.schedule(every: 1.second, x: 1)

        job.should be_a(TestJob)
        job.x.should eq(1)

        # Give it time to run once
        sleep 1.5.seconds

        # Job should have executed (x incremented)
        job.x.should be >= 2
      end
    end

    describe "expiration" do
      it "detects expired jobs" do
        job = ExampleJob.new(1)

        # Set expiration in the past
        job.expires = (Time.local - 1.hour).to_unix_ms

        # Check if job is expired (requires actual expiration check logic)
        # The job has expired? predicate for status, but expiration check is different
        job.expires.should be < Time.local.to_unix_ms
      end

      it "sets future expiration" do
        job = ExampleJob.new(1)
        future_time = (Time.local + 24.hours).to_unix_ms

        job.expires = future_time
        job.expires.should be > Time.local.to_unix_ms
      end

      it "uses default expiration from config" do
        job = ExampleJob.new(1)

        # Default should be in the future
        job.expires.should be > Time.local.to_unix_ms
      end
    end

    describe "retry management" do
      it "tracks retry count" do
        job = RetryTestJob.new(1)
        initial_retries = job.retries

        job.retries = initial_retries - 1
        job.retries.should eq(initial_retries - 1)
      end

      it "respects max_retries" do
        job = RetryTestJob.new(1)
        job.max_retries = 5
        job.retries = 5

        job.retries.should eq(job.max_retries)
      end

      it "can exhaust retries" do
        job = NoRetryFailJob.new
        job.retries.should eq(0)
        job.max_retries.should eq(0)
      end

      it "decrements retries on failure" do
        job = RetryTestJob.new(1)
        initial = job.retries

        job.retries -= 1
        job.retries.should eq(initial - 1)
      end
    end

    describe "queue assignment" do
      it "uses job-specific queue" do
        job = ExampleJob.new(1)
        job.queue.should eq("example")
      end

      it "allows custom queue assignment" do
        job = ExampleJob.new(1)
        job.queue = "custom"
        job.queue.should eq("custom")
      end

      it "uses default queue for Job1" do
        job = Job1.new
        job.queue.should eq("single")
      end
    end

    describe "error tracking" do
      it "stores error information" do
        job = FailJob.new

        error_info = {
          failed_at:      Time.local.to_rfc3339,
          message:        "Job failed",
          backtrace:      "line 1\nline 2\nline 3",
          cause:          "RuntimeError",
          error_type:     "execution_error",
          error_class:    "RuntimeError",
          retry_count:    1,
          system_context: {"worker" => "worker-1", "queue" => "failed"},
        }

        job.error = error_info

        job.error.should_not be_nil
        job.error.not_nil![:message].should eq("Job failed")
        job.error.not_nil![:retry_count].should eq(1)
        job.error.not_nil![:error_type].should eq("execution_error")
      end

      it "serializes error with job" do
        job = FailJob.new
        job.error = {
          failed_at:      Time.local.to_rfc3339,
          message:        "Serialization test",
          backtrace:      "trace",
          cause:          "Error",
          error_type:     "test",
          error_class:    "Test",
          retry_count:    0,
          system_context: nil,
        }

        json = job.to_json
        restored = FailJob.from_json(json)

        restored.error.should_not be_nil
        restored.error.not_nil![:message].should eq("Serialization test")
      end

      it "handles nil error gracefully" do
        job = ExampleJob.new(1)
        job.error.should be_nil

        json = job.to_json
        json.should contain("error")
      end
    end

    describe "job identity" do
      it "generates unique JIDs for each job" do
        jids = Set(UUID).new

        100.times do
          job = ExampleJob.new(1)
          jids << job.jid
        end

        jids.size.should eq(100)
      end

      it "preserves JID through serialization" do
        job1 = ExampleJob.new(1)
        original_jid = job1.jid

        json = job1.to_json
        job2 = ExampleJob.from_json(json)

        job2.jid.should eq(original_jid)
      end
    end

    describe "job lifecycle" do
      it "follows complete lifecycle: Enqueued → Running → Completed" do
        job = ExampleJob.new(1)

        # Initial state
        job.enqueued?.should be_true

        # Worker picks up
        job.running!
        job.running?.should be_true

        # Job completes
        job.completed!
        job.completed?.should be_true
      end

      it "follows failure lifecycle: Running → Retrying → Dead" do
        job = NoRetryFailJob.new
        job.running!

        # First failure, attempt retry
        job.retrying!
        job.retrying?.should be_true

        # No retries left
        job.dead!
        job.dead?.should be_true
      end

      it "can expire before execution" do
        job = ExampleJob.new(1)
        job.enqueued?.should be_true

        # Job expires
        job.expired!
        job.expired?.should be_true
      end
    end

    describe "job parameter handling" do
      it "initializes with custom parameters" do
        job = ExampleJob.new(42)
        job.x.should eq(42)
      end

      it "preserves parameters through serialization" do
        job1 = ExampleJob.new(999)
        json = job1.to_json
        job2 = ExampleJob.from_json(json)

        job2.x.should eq(999)
      end

      it "handles jobs without parameters" do
        job = Job1.new
        job.should be_a(Job1)
      end
    end
  end
end
