module JoobQ
  module Middleware
    abstract def matches?(job : Job, queue : BaseQueue) : Bool
    abstract def call(job : Job, queue : BaseQueue, worker_id : String, next_middleware : ->) : Nil
  end

  class MiddlewarePipeline
    @middlewares : Array(Middleware)

    def initialize(@middlewares : Array(Middleware) = [] of Middleware)
    end

    def call(job : Job, queue : BaseQueue, worker_id : String, &block : ->)
      call_next(0, job, queue, worker_id, &block)
    end

    private def call_next(index : Int32, job : Job, queue : BaseQueue, worker_id : String, &block : ->)
      if index < @middlewares.size
        middleware = @middlewares[index]
        if middleware.matches?(job, queue)
          middleware.call(job, queue, worker_id, -> { call_next(index + 1, job, queue, worker_id, &block) })
        else
          call_next(index + 1, job, queue, worker_id, &block)
        end
      else
        yield
      end
    end
  end
end
