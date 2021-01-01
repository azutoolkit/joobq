module JoobQ
  enum Status
    Retry
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
