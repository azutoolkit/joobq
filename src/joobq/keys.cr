module JoobQ
  # The names of the Redis keys JoobQ owns. Every key lives under `PREFIX`, one versioned namespace, so JoobQ cannot
  # collide with another application on a shared Redis, and a later layout change is told apart by its version.
  # Code that needs a key asks here rather than building the string (a queue's list is `Keys.queue(name)`, never
  # the bare queue name).
  module Keys
    PREFIX = "joobq:v1"

    # The list of the jobs waiting in the queue called *name*: producers RPUSH to its tail, workers claim from its head.
    def self.queue(name : String) : String
      "#{PREFIX}:queue:#{name}"
    end
  end
end
