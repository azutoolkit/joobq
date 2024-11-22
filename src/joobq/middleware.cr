module JoobQ
  module Middleware
    abstract def matches?(job : Job, queue : BaseQueue) : Bool
    abstract def call(job : Job, queue : BaseQueue, next_middleware : ->) : Nil
  end

  class MiddlewarePipeline
    @middlewares : Array(Middleware)

    def initialize(@middlewares : Array(Middleware) = [] of Middleware)
    end

    def call(job : Job, queue : BaseQueue, &block : ->)
      call_next(0, job, queue, &block)
    end

    private def call_next(index : Int32, job : Job, queue : BaseQueue, &block : ->)
      if index < @middlewares.size
        middleware = @middlewares[index]
        if middleware.matches?(job, queue)
          middleware.call(job, queue, -> { call_next(index + 1, job, queue, &block) })
        else
          call_next(index + 1, job, queue, &block)
        end
      else
        yield
      end
    end
  end
end
