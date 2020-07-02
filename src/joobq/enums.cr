module JoobQ
  enum Queues
    Busy
    Completed
  end

  enum Sets
    Delayed
    Retry
    Dead
  end

  enum Control
    Stop
  end
end
