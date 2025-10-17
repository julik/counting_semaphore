require_relative "counting_semaphore/version"

module CountingSemaphore
  # Custom exception for lease acquisition timeouts
  class LeaseTimeout < StandardError
    attr_reader :semaphore, :token_count, :timeout_seconds

    def initialize(token_count, timeout_seconds, semaphore = nil)
      @token_count = token_count
      @timeout_seconds = timeout_seconds
      @semaphore = semaphore
      super("Failed to acquire #{token_count} tokens within #{timeout_seconds} seconds")
    end
  end

  autoload :LocalSemaphore, "counting_semaphore/local_semaphore"
  autoload :RedisSemaphore, "counting_semaphore/redis_semaphore"
  autoload :NullLogger, "counting_semaphore/null_logger"
end
