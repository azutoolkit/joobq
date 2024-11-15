module JoobQ
  class Timeout
    class TimeoutError < Exception; end

    # Executes the given block with a timeout. If the block takes longer than the specified
    # timeout (in seconds) to complete, it raises a Timeout::TimeoutError.
    #
    # @param timeout [Int32] the maximum duration in seconds that the block is allowed to run
    # @yield the block of code to execute with a timeout
    # @raise Timeout::TimeoutError if the block exceeds the specified timeout
    def self.run(timeout : Time::Span, &block : ->)
      timeout_channel = Channel(Nil).new

      # Fiber to run the block
      task_fiber = spawn do
        begin
          block.call
          timeout_channel.send(nil) # Send a signal when done
        rescue ex
          timeout_channel.send(nil) # Send a signal even if there's an exception
          raise ex
        end
      end

      # Start a timer fiber to enforce the timeout
      spawn do
        sleep timeout
        timeout_channel.close # Close the channel if timeout is reached
      end

      # Wait on the channel to check if the task completed in time
      if timeout_channel.receive?
        # Task completed within the timeout
        true
      else
        # Task exceeded the timeout, so we raise an error and terminate the task fiber
        task_fiber.terminate
        raise TimeoutError.new("execution expired after #{timeout} seconds")
      end
    end
  end
end
