module JoobQ
  enum Queues
    Busy
    Completed
  end

  enum Sets
    Delayed
    Failed
    Retry
    Dead
  end
end
