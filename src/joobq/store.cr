module JoobQ
  # Define a generic Store interface
  abstract class Store
    abstract def clear_queue(queue_name : String) : Nil
    abstract def delete_job(job : JoobQ::Job) : Nil
    abstract def enqueue(job : JoobQ::Job) : String
    abstract def dequeue(queue_name : String, klass : Class) : Job?
    abstract def move_job_back_to_queue(queue_name : String) : Bool
    abstract def mark_as_failed(job : JoobQ::Job, error_details : Hash) : Nil
    abstract def mark_as_dead(job : JoobQ::Job, expiration_time : String) : Nil
    abstract def schedule(job : JoobQ::Job, delay_in_ms : Int64) : Nil
    abstract def fetch_due_jobs(current_time : Time) : Array(String)
    abstract def queue_size(queue_name : String) : Int64
    abstract def list_jobs(queue_name : String, page_number : Int32 = 1, page_size : Int32 = 200) : Array(String)
  end
end
