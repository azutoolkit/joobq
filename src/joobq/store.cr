module JoobQ
  # Define a generic Store interface
  abstract class Store
    # Operations related to resetting the store
    abstract def reset : Nil

    # Adding a job to the store
    abstract def add(job : JoobQ::Job) : String

    # Pushing a job into the queue with additional settings
    abstract def push(job : JoobQ::Job) : String

    # Retrieve a job by its ID, returning an instance of the provided class
    abstract def find(job_id : String | UUID, klass : Class) : JoobQ::Job?

    # Fetch the next job from the queue, returns an instance of the provided class
    abstract def get(queue_name : String, klass : Class) : JoobQ::Job?

    # Mark a job as done with the associated duration for the job
    abstract def done(job : JoobQ::Job, duration : Float64) : Nil

    # Mark a job as failed with associated details
    abstract def failed(job : JoobQ::Job, duration : Float64) : Nil

    # Moves jobs to a "dead" state after they expire
    abstract def dead(job : JoobQ::Job, expires : Float64) : Nil

    # Add a job to the delayed set, to be executed after a certain time
    abstract def add_delayed(job : JoobQ::Job, till : Time::Span) : Nil

    # Retrieve jobs from the delayed set that are due to be processed
    abstract def get_delayed(now : Time) : Array(String)

    # Remove a job from the delayed set and optionally add it to another queue
    abstract def remove_delayed(job : JoobQ::Job, queue : Array(String)) : Bool

    # Tracks successful job processing time to determine the average processing time
    abstract def success(job, start)

    # Tracks failed job processing time to determine the average processing time
    abstract def fail(job, start)

    # Tracks processed job processing time to determine the average processing time
    abstract def processed(job, start)
  end
end
