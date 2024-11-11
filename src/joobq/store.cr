module JoobQ
  # Define a generic Store interface
  abstract class Store
    # Pushes a job to the queue
    abstract def push(job : JoobQ::Job) : String
    # Fetch the next job from the queue, returns an instance of the provided class
    abstract def get(queue : String, target_queue : String, klass : Class) : Job?
    # Mark a job as failed with associated details
    abstract def failed(job : JoobQ::Job, error : Hash) : Nil
    # Moves jobs to a "dead" state after they expire
    abstract def dead(job : JoobQ::Job, expires : Float64) : Nil
    # Add a job to the delayed set, to be executed after a certain time
    abstract def add_delayed(job : JoobQ::Job, till : Time::Span) : Nil
    # Retrieve jobs from the delayed set that are due to be processed
    abstract def get_delayed(now : Time) : Array(String)
    # Remove a job from the delayed set and optionally add it to another queue
    abstract def remove_delayed(job : JoobQ::Job) : Int64
    # Returns a list of jobs from the specified queue
    abstract def list(queue : String, page_number : Int32 = 1, page_size : Int32 = 200) : Array(Job)
  end
end
