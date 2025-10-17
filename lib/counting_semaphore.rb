require "counting_semaphore/version"

module CountingSemaphore
  autoload :LocalSemaphore, "counting_semaphore/local_semaphore"
  autoload :RedisSemaphore, "counting_semaphore/redis_semaphore"
  autoload :NullLogger, "counting_semaphore/null_logger"
end
