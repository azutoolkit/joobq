# Specs only: reaches the worker's private handling of a payload that cannot be parsed.
class JoobQ::Worker(T)
  def test_unparseable(job_json : String, error : Exception) : Nil
    handle_unparseable_job(job_json, error)
  end
end
