# A counting semaphore that allows up to N concurrent operations.
# When capacity is exceeded, operations block until resources become available.
module CountingSemaphore
  class LocalSemaphore
    SLEEP_WAIT_SECONDS = 0.25

    # @return [Integer]
    attr_reader :capacity

    # Initialize the semaphore with a maximum capacity.
    #
    # @param capacity [Integer] Maximum number of concurrent operations allowed
    # @param logger [Logger] the logger
    # @raise [ArgumentError] if capacity is not positive
    def initialize(capacity, logger: CountingSemaphore::NullLogger)
      raise ArgumentError, "Capacity must be positive, got #{capacity}" unless capacity > 0
      @capacity = capacity.to_i
      @leased = 0
      @mutex = Mutex.new
      @condition = ConditionVariable.new
      @logger = logger
    end

    # Acquire a lease for the specified number of tokens and execute the block.
    # Blocks until sufficient resources are available.
    #
    # @param token_count [Integer] Number of tokens to acquire
    # @param timeout_seconds [Integer] Maximum time to wait for lease acquisition (default: 30 seconds)
    # @yield The block to execute while holding the lease
    # @return The result of the block
    # @raise [ArgumentError] if token_count is negative or exceeds the semaphore capacity
    # @raise [Timeout::Error] if lease cannot be acquired within timeout
    def with_lease(token_count_num = 1, timeout_seconds: 30)
      token_count = token_count_num.to_i
      raise ArgumentError, "Token count must be non-negative, got #{token_count}" if token_count < 0
      if token_count > @capacity
        raise ArgumentError, "Cannot lease #{token_count} slots as we only allow #{@capacity}"
      end

      # Handle zero tokens case - no waiting needed
      return yield if token_count.zero?

      did_accept = false
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      loop do
        # Check timeout
        elapsed_time = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
        if elapsed_time >= timeout_seconds
          raise Timeout::Error, "Failed to acquire #{token_count} tokens within #{timeout_seconds} seconds"
        end

        did_accept = @mutex.synchronize do
          if (@capacity - @leased) >= token_count
            @leased += token_count
            true
          else
            false
          end
        end

        if did_accept
          @logger.debug { "Leased #{token_count} and now in use #{@leased}/#{@capacity}" }
          return yield
        end

        @logger.debug { "Unable to lease #{token_count}, #{@leased}/#{@capacity} waiting" }

        # Wait on condition variable with remaining timeout
        remaining_timeout = timeout_seconds - elapsed_time
        if remaining_timeout > 0
          @mutex.synchronize do
            @condition.wait(@mutex, remaining_timeout)
          end
        end
      end
    ensure
      if did_accept
        @logger.debug { "Returning #{token_count} leased slots" }
        @mutex.synchronize do
          @leased -= token_count
          @condition.broadcast # Signal waiting threads
        end
      end
    end

    # Get the current number of tokens currently leased
    #
    # @return [Integer] Number of tokens currently in use
    def currently_leased
      @mutex.synchronize { @leased }
    end
  end
end
