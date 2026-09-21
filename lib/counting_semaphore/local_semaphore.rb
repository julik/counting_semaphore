# frozen_string_literal: true

# A counting semaphore that allows up to N concurrent operations.
# When capacity is exceeded, operations block until resources become available.
# API compatible with concurrent-ruby's Semaphore class.
module CountingSemaphore
  class LocalSemaphore
    include WithLeaseSupport

    SLEEP_WAIT_SECONDS = 0.25

    # @return [Integer]
    attr_reader :capacity

    # Initialize the semaphore with a maximum capacity.
    #
    # @param capacity [Integer] Maximum number of concurrent operations allowed (also called permits)
    # @param logger [Logger] the logger
    # @raise [ArgumentError] if capacity is not positive
    def initialize(capacity, logger: CountingSemaphore::NullLogger)
      raise ArgumentError, "Capacity must be positive, got #{capacity}" unless capacity >= 1
      @capacity = capacity.to_i
      @acquired = 0
      @mutex = Mutex.new
      @condition = ConditionVariable.new
      @logger = logger
    end

    # Acquires the given number of permits from this semaphore, blocking until all are available.
    #
    # @param permits [Integer] Number of permits to acquire (default: 1)
    # @return [CountingSemaphore::Lease] A lease object that must be passed to release()
    # @raise [ArgumentError] if permits is not an integer or is less than one
    def acquire(permits = 1)
      permits = permits.to_i
      raise ArgumentError, "Permits must be at least 1, got #{permits}" if permits < 1
      if permits > @capacity
        raise ArgumentError, "Cannot acquire #{permits} permits as capacity is only #{@capacity}"
      end

      loop do
        acquired = @mutex.synchronize do
          if (@capacity - @acquired) >= permits
            @acquired += permits
            @logger.debug { "Acquired #{permits} permits, now #{@acquired}/#{@capacity}" }
            true
          else
            false
          end
        end

        if acquired
          lease_id = "local_#{object_id}_#{Time.now.to_f}_#{rand(1000000)}"
          return CountingSemaphore::Lease.new(
            semaphore: self,
            id: lease_id,
            permits: permits
          )
        end

        @logger.debug { "Unable to acquire #{permits} permits, #{@acquired}/#{@capacity} in use, waiting" }
        @mutex.synchronize do
          @condition.wait(@mutex)
        end
      end
    end

    # Releases a previously acquired lease, returning the permits to the semaphore.
    #
    # @param lease [CountingSemaphore::Lease] The lease object returned by acquire() or try_acquire()
    # @return [nil]
    # @raise [ArgumentError] if lease belongs to a different semaphore
    def release(lease)
      unless lease.semaphore == self
        raise ArgumentError, "Lease belongs to a different semaphore"
      end

      permits = lease.permits

      @mutex.synchronize do
        @acquired -= permits
        @logger.debug { "Released #{permits} permits (lease: #{lease.id}), now #{@acquired}/#{@capacity}" }
        @condition.broadcast # Signal waiting threads
      end
      nil
    end

    # Acquires the given number of permits from this semaphore, only if all are available
    # at the time of invocation or within the timeout interval.
    #
    # @param permits [Integer] Number of permits to acquire (default: 1)
    # @param timeout [Numeric, nil] Number of seconds to wait, or nil to return immediately (default: nil)
    # @return [CountingSemaphore::Lease, nil] A lease object if successful, nil otherwise
    # @raise [ArgumentError] if permits is not an integer or is less than one
    def try_acquire(permits = 1, timeout: nil)
      permits = permits.to_i
      raise ArgumentError, "Permits must be at least 1, got #{permits}" if permits < 1
      if permits > @capacity
        return nil
      end

      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC) if timeout

      loop do
        # Check timeout
        if timeout
          elapsed_time = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
          return nil if elapsed_time >= timeout
        end

        acquired = @mutex.synchronize do
          if (@capacity - @acquired) >= permits
            @acquired += permits
            @logger.debug { "Acquired #{permits} permits (try), now #{@acquired}/#{@capacity}" }
            true
          else
            false
          end
        end

        if acquired
          lease_id = "local_#{object_id}_#{Time.now.to_f}_#{rand(1000000)}"
          return CountingSemaphore::Lease.new(
            semaphore: self,
            id: lease_id,
            permits: permits
          )
        end

        # If no timeout, return immediately
        return nil if timeout.nil?

        # Wait with remaining timeout
        remaining_timeout = timeout - (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time)
        return nil if remaining_timeout <= 0

        @mutex.synchronize do
          @condition.wait(@mutex, remaining_timeout)
        end
      end
    end

    # Returns the current number of permits available in this semaphore.
    #
    # @return [Integer] Number of available permits
    def available_permits
      @mutex.synchronize { @capacity - @acquired }
    end

    # Acquires and returns all permits that are immediately available.
    # Returns a single lease representing all drained permits.
    #
    # @return [CountingSemaphore::Lease, nil] A lease for all available permits, or nil if none available
    def drain_permits
      permits = @mutex.synchronize do
        available = @capacity - @acquired
        if available > 0
          @acquired = @capacity
          @logger.debug { "Drained #{available} permits" }
          available
        else
          0
        end
      end

      if permits > 0
        lease_id = "local_#{object_id}_#{Time.now.to_f}_#{rand(1000000)}"
        CountingSemaphore::Lease.new(
          semaphore: self,
          id: lease_id,
          permits: permits
        )
      end
    end
  end
end
