# frozen_string_literal: true

require_relative "counting_semaphore/version"

module CountingSemaphore
  # Represents an acquired lease on a semaphore.
  # Must be passed to release() to return the permits.
  Lease = Struct.new(:semaphore, :id, :permits, keyword_init: true) do
    # Returns a human-readable representation of the lease
    #
    # @return [String]
    def to_s
      "Lease(#{permits} permits, id: #{id})"
    end

    # Returns detailed inspection string
    #
    # @return [String]
    def inspect
      "#<CountingSemaphore::Lease permits=#{permits} id=#{id.inspect}>"
    end
  end

  # Custom exception raised when a semaphore lease cannot be acquired within the specified timeout.
  # Contains information about the failed acquisition attempt including the semaphore instance,
  # number of permits requested, and the timeout duration.
  class LeaseTimeout < StandardError
    # @return [CountingSemaphore::LocalSemaphore, CountingSemaphore::RedisSemaphore, nil] The semaphore that timed out
    # @return [Integer] The number of permits that were requested
    # @return [Numeric] The timeout duration in seconds
    attr_reader :semaphore, :permit_count, :timeout_seconds

    # For backwards compatibility, also provide token_count as an alias
    alias_method :token_count, :permit_count

    # Creates a new LeaseTimeout exception.
    #
    # @param permit_count [Integer] Number of permits that were requested
    # @param timeout_seconds [Numeric] The timeout duration that was exceeded
    # @param semaphore [CountingSemaphore::LocalSemaphore, CountingSemaphore::RedisSemaphore, nil] The semaphore instance (optional)
    def initialize(permit_count, timeout_seconds, semaphore = nil)
      @permit_count = permit_count
      @timeout_seconds = timeout_seconds
      @semaphore = semaphore
      super("Failed to acquire #{permit_count} permits within #{timeout_seconds} seconds")
    end
  end

  autoload :LocalSemaphore, "counting_semaphore/local_semaphore"
  autoload :RedisSemaphore, "counting_semaphore/redis_semaphore"
  autoload :NullLogger, "counting_semaphore/null_logger"
  autoload :WithLeaseSupport, "counting_semaphore/with_lease_support"
end
