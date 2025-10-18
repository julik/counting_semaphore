# frozen_string_literal: true

module CountingSemaphore
  # Module providing backwards-compatible with_lease method
  # Requires the including class to implement: acquire, release, capacity
  module WithLeaseSupport
    # Acquire a lease for the specified number of permits and execute the block.
    # Blocks until sufficient resources are available.
    # Kept for backwards compatibility - wraps acquire/release.
    #
    # @param permit_count [Integer] Number of permits to acquire (default: 1)
    # @param timeout_seconds [Integer] Maximum time to wait for lease acquisition (default: 30 seconds)
    # @yield [lease] The block to execute while holding the lease
    # @yieldparam lease [CountingSemaphore::Lease, nil] The lease object (nil if permit_count is 0)
    # @return The result of the block
    # @raise [ArgumentError] if permit_count is negative or exceeds the semaphore capacity
    # @raise [CountingSemaphore::LeaseTimeout] if lease cannot be acquired within timeout
    def with_lease(permit_count = 1, timeout_seconds: 30)
      permit_count = permit_count.to_i
      raise ArgumentError, "Permit count must be non-negative, got #{permit_count}" if permit_count < 0
      if permit_count > capacity
        raise ArgumentError, "Cannot lease #{permit_count} permits as capacity is only #{capacity}"
      end

      # Handle zero permits case - no waiting needed
      return yield(nil) if permit_count.zero?

      # Use try_acquire with timeout
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      lease = nil

      loop do
        elapsed_time = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
        if elapsed_time >= timeout_seconds
          raise CountingSemaphore::LeaseTimeout.new(permit_count, timeout_seconds, self)
        end

        remaining_timeout = timeout_seconds - elapsed_time
        lease = try_acquire(permit_count, remaining_timeout)
        break if lease
      end

      begin
        yield(lease)
      ensure
        release(lease) if lease
      end
    end

    # Get the current number of permits currently acquired.
    # Kept for backwards compatibility.
    #
    # @return [Integer] Number of permits currently in use
    def currently_leased
      capacity - available_permits
    end
  end
end
