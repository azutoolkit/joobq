module JoobQ
  class Timeout
    # The `Timeout` class in the [`JoobQ`](JoobQ ) module provides a mechanism to execute a block of code with a
    # specified timeout. If the block takes longer than the specified timeout to complete, it
    # raises a `Timeout::TimeoutError`.
    #
    # ### Properties
    #
    # - `TimeoutError < Exception` - Custom exception raised when a block exceeds the specified timeout.
    #
    # ### Methods
    #
    # #### `run`
    #
    # ```
    # def self.run(timeout : Time::Span, &block : ->)
    # ```
    #
    # Executes the given block with a timeout. If the block takes longer than the specified timeout (in seconds) to
    # complete, it raises a `Timeout::TimeoutError`.
    #
    # - **Parameters**:
    #   - `timeout` (`Time::Span`): The maximum duration that the block is allowed to run.
    #   - `block` (`->`): The block of code to execute with a timeout.
    # - **Raises**:
    #   - `Timeout::TimeoutError` if the block exceeds the specified timeout.
    #
    # ### Usage
    #
    # #### Executing a Block with a Timeout
    #
    # To execute a block of code with a timeout, use the `run` method:
    #
    # ```
    # begin
    #   JoobQ::Timeout.run(5.seconds) do
    #     # Your code here
    #     sleep 10 # Simulate a long-running task
    #   end
    # rescue JoobQ::Timeout::TimeoutError
    #   puts "The block exceeded the timeout!"
    # end
    # ```
    #
    # ### Workflow
    #
    # 1. **Initialization**:
    #   - The `run` method is called with a specified timeout and a block of code.
    #   - A `timeout_channel` is created to signal the completion or timeout of the block.
    #
    # 2. **Executing the Block**:
    #   - A fiber (`task_fiber`) is spawned to execute the block.
    #   - The block is called, and upon completion, a signal is sent through the `timeout_channel`.
    #   - If an exception occurs within the block, the signal is still sent, and the exception is re-raised.
    #
    # 3. **Enforcing the Timeout**:
    #   - Another fiber is spawned to enforce the timeout.
    #   - The fiber sleeps for the specified timeout duration and then closes the `timeout_channel`.
    #
    # 4. **Checking Completion**:
    #   - The method waits on the `timeout_channel` to check if the block completed within the timeout.
    #   - If the block completes within the timeout, the method returns `true`.
    #   - If the block exceeds the timeout, a `Timeout::TimeoutError` is raised, and the `task_fiber` is terminated.
    #
    # ### Example
    #
    # Here is a complete example demonstrating how to use the `Timeout` class:
    #
    # ```
    # require "joobq"
    #
    # begin
    #   JoobQ::Timeout.run(5.seconds) do
    #     puts "Starting a task..."
    #     sleep 10 # Simulate a long-running task
    #     puts "Task completed!"
    #   end
    # rescue JoobQ::Timeout::TimeoutError
    #   puts "The block exceeded the timeout!"
    # end
    # ```
    #
    # This example attempts to execute a block that sleeps for 10 seconds with a timeout of 5 seconds. Since the block
    # exceeds the timeout, a `Timeout::TimeoutError` is raised, and the message "The block exceeded the timeout!"
    # is printed.
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
