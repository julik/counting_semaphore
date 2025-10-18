# typed: strong
# A counting semaphore that allows up to N concurrent operations.
# When capacity is exceeded, operations block until resources become available.
# API compatible with concurrent-ruby's Semaphore class.
module CountingSemaphore
  VERSION = T.let("0.1.0", T.untyped)

  # Represents an acquired lease on a semaphore.
  # Must be passed to release() to return the permits.
  class Lease < Struct
    # Returns a human-readable representation of the lease
    sig { returns(String) }
    def to_s; end

    # Returns detailed inspection string
    sig { returns(String) }
    def inspect; end

    # Returns the value of attribute semaphore
    sig { returns(Object) }
    attr_accessor :semaphore

    # Returns the value of attribute lease_id
    sig { returns(Object) }
    attr_accessor :lease_id

    # Returns the value of attribute permits
    sig { returns(Object) }
    attr_accessor :permits
  end

  # Custom exception raised when a semaphore lease cannot be acquired within the specified timeout.
  # Contains information about the failed acquisition attempt including the semaphore instance,
  # number of permits requested, and the timeout duration.
  class LeaseTimeout < StandardError
    # Creates a new LeaseTimeout exception.
    # 
    # _@param_ `permit_count` — Number of permits that were requested
    # 
    # _@param_ `timeout_seconds` — The timeout duration that was exceeded
    # 
    # _@param_ `semaphore` — The semaphore instance (optional)
    sig { params(permit_count: Integer, timeout_seconds: Numeric, semaphore: T.nilable(T.any(CountingSemaphore::LocalSemaphore, CountingSemaphore::RedisSemaphore))).void }
    def initialize(permit_count, timeout_seconds, semaphore = nil); end

    # _@return_ — The semaphore that timed out
    # 
    # _@return_ — The number of permits that were requested
    # 
    # _@return_ — The timeout duration in seconds
    sig { returns(T.nilable(T.any(CountingSemaphore::LocalSemaphore, CountingSemaphore::RedisSemaphore, Integer, Numeric))) }
    attr_reader :semaphore

    # _@return_ — The semaphore that timed out
    # 
    # _@return_ — The number of permits that were requested
    # 
    # _@return_ — The timeout duration in seconds
    sig { returns(T.nilable(T.any(CountingSemaphore::LocalSemaphore, CountingSemaphore::RedisSemaphore, Integer, Numeric))) }
    attr_reader :permit_count

    # _@return_ — The semaphore that timed out
    # 
    # _@return_ — The number of permits that were requested
    # 
    # _@return_ — The timeout duration in seconds
    sig { returns(T.nilable(T.any(CountingSemaphore::LocalSemaphore, CountingSemaphore::RedisSemaphore, Integer, Numeric))) }
    attr_reader :timeout_seconds
  end

  # A null logger that discards all log messages.
  # Provides the same interface as a real logger but does nothing.
  # Only yields blocks when ENV["RUN_ALL_LOGGER_BLOCKS"] is set to "yes",
  # which is useful in testing. Block form for Logger calls allows you
  # to skip block evaluation if the Logger level is higher than your
  # call, and thus bugs can nest in those Logger blocks. During
  # testing it is helpful to excercise those blocks unconditionally.
  module NullLogger
    extend CountingSemaphore::NullLogger

    # Logs a debug message. Discards the message but may yield the block for testing.
    # 
    # _@param_ `message` — Optional message to log (discarded)
    sig { params(message: T.nilable(String), block: T.untyped).void }
    def debug(message = nil, &block); end

    # Logs an info message. Discards the message but may yield the block for testing.
    # 
    # _@param_ `message` — Optional message to log (discarded)
    sig { params(message: T.nilable(String), block: T.untyped).void }
    def info(message = nil, &block); end

    # Logs a warning message. Discards the message but may yield the block for testing.
    # 
    # _@param_ `message` — Optional message to log (discarded)
    sig { params(message: T.nilable(String), block: T.untyped).void }
    def warn(message = nil, &block); end

    # Logs an error message. Discards the message but may yield the block for testing.
    # 
    # _@param_ `message` — Optional message to log (discarded)
    sig { params(message: T.nilable(String), block: T.untyped).void }
    def error(message = nil, &block); end

    # Logs a fatal message. Discards the message but may yield the block for testing.
    # 
    # _@param_ `message` — Optional message to log (discarded)
    sig { params(message: T.nilable(String), block: T.untyped).void }
    def fatal(message = nil, &block); end

    # Logs a debug message. Discards the message but may yield the block for testing.
    # 
    # _@param_ `message` — Optional message to log (discarded)
    sig { params(message: T.nilable(String), block: T.untyped).void }
    def self.debug(message = nil, &block); end

    # Logs an info message. Discards the message but may yield the block for testing.
    # 
    # _@param_ `message` — Optional message to log (discarded)
    sig { params(message: T.nilable(String), block: T.untyped).void }
    def self.info(message = nil, &block); end

    # Logs a warning message. Discards the message but may yield the block for testing.
    # 
    # _@param_ `message` — Optional message to log (discarded)
    sig { params(message: T.nilable(String), block: T.untyped).void }
    def self.warn(message = nil, &block); end

    # Logs an error message. Discards the message but may yield the block for testing.
    # 
    # _@param_ `message` — Optional message to log (discarded)
    sig { params(message: T.nilable(String), block: T.untyped).void }
    def self.error(message = nil, &block); end

    # Logs a fatal message. Discards the message but may yield the block for testing.
    # 
    # _@param_ `message` — Optional message to log (discarded)
    sig { params(message: T.nilable(String), block: T.untyped).void }
    def self.fatal(message = nil, &block); end
  end

  class LocalSemaphore
    include CountingSemaphore::WithLeaseSupport
    SLEEP_WAIT_SECONDS = T.let(0.25, T.untyped)

    # Initialize the semaphore with a maximum capacity.
    # 
    # _@param_ `capacity` — Maximum number of concurrent operations allowed (also called permits)
    # 
    # _@param_ `logger` — the logger
    sig { params(capacity: Integer, logger: Logger).void }
    def initialize(capacity, logger: CountingSemaphore::NullLogger); end

    # Acquires the given number of permits from this semaphore, blocking until all are available.
    # 
    # _@param_ `permits` — Number of permits to acquire (default: 1)
    # 
    # _@return_ — A lease object that must be passed to release()
    sig { params(permits: Integer).returns(CountingSemaphore::Lease) }
    def acquire(permits = 1); end

    # Releases a previously acquired lease, returning the permits to the semaphore.
    # 
    # _@param_ `lease` — The lease object returned by acquire() or try_acquire()
    sig { params(lease: CountingSemaphore::Lease).void }
    def release(lease); end

    # Acquires the given number of permits from this semaphore, only if all are available
    # at the time of invocation or within the timeout interval.
    # 
    # _@param_ `permits` — Number of permits to acquire (default: 1)
    # 
    # _@param_ `timeout` — Number of seconds to wait, or nil to return immediately (default: nil)
    # 
    # _@return_ — A lease object if successful, nil otherwise
    sig { params(permits: Integer, timeout: T.nilable(Numeric)).returns(T.nilable(CountingSemaphore::Lease)) }
    def try_acquire(permits = 1, timeout = nil); end

    # Returns the current number of permits available in this semaphore.
    # 
    # _@return_ — Number of available permits
    sig { returns(Integer) }
    def available_permits; end

    # Acquires and returns all permits that are immediately available.
    # Returns a single lease representing all drained permits.
    # 
    # _@return_ — A lease for all available permits, or nil if none available
    sig { returns(T.nilable(CountingSemaphore::Lease)) }
    def drain_permits; end

    # Acquire a lease for the specified number of permits and execute the block.
    # Blocks until sufficient resources are available.
    # Kept for backwards compatibility - wraps acquire/release.
    # 
    # _@param_ `permit_count` — Number of permits to acquire (default: 1)
    # 
    # _@param_ `timeout_seconds` — Maximum time to wait for lease acquisition (default: 30 seconds)
    # 
    # _@return_ — The result of the block
    sig { params(permit_count: Integer, timeout_seconds: Integer, blk: T.proc.params(lease: T.nilable(CountingSemaphore::Lease)).void).returns(T.untyped) }
    def with_lease(permit_count = 1, timeout_seconds: 30, &blk); end

    # Get the current number of permits currently acquired.
    # Kept for backwards compatibility.
    # 
    # _@return_ — Number of permits currently in use
    sig { returns(Integer) }
    def currently_leased; end

    sig { returns(Integer) }
    attr_reader :capacity
  end

  class RedisSemaphore
    include CountingSemaphore::WithLeaseSupport
    LEASE_EXPIRATION_SECONDS = T.let(5, T.untyped)
    GET_LEASE_SCRIPT = T.let(<<~LUA, T.untyped)
  local lease_key = KEYS[1]
  local lease_set_key = KEYS[2]
  local capacity = tonumber(ARGV[1])
  local token_count = tonumber(ARGV[2])
  local expiration_seconds = tonumber(ARGV[3])
  
  -- Get all active leases from the set and calculate current usage
  local lease_keys = redis.call('SMEMBERS', lease_set_key)
  local current_usage = 0
  local valid_leases = {}
  
  for i, key in ipairs(lease_keys) do
    local tokens = redis.call('GET', key)
    if tokens then
      local tokens_from_lease = tonumber(tokens)
      if tokens_from_lease then
        current_usage = current_usage + tokens_from_lease
        table.insert(valid_leases, key)
      else
        -- Remove lease with invalid token count
        redis.call('DEL', key)
        redis.call('SREM', lease_set_key, key)
      end
    else
      -- Lease key doesn't exist, remove from set
      redis.call('SREM', lease_set_key, key)
    end
  end
  
  -- Check if we have capacity
  local available = capacity - current_usage
  if available >= token_count then
    -- Set lease with TTL (value is just the token count)
    redis.call('SETEX', lease_key, expiration_seconds, token_count)
    -- Add lease key to the set
    redis.call('SADD', lease_set_key, lease_key)
    -- Set TTL on the set (4x the lease TTL to ensure cleanup)
    redis.call('EXPIRE', lease_set_key, expiration_seconds * 4)
    
    return {1, lease_key, current_usage + token_count}
  else
    return {0, '', current_usage}
  end
LUA
    GET_USAGE_SCRIPT = T.let(<<~LUA, T.untyped)
  local lease_set_key = KEYS[1]
  local expiration_seconds = tonumber(ARGV[1])
  
  -- Get all active leases from the set and calculate current usage
  local lease_keys = redis.call('SMEMBERS', lease_set_key)
  local current_usage = 0
  local has_valid_leases = false
  
  for i, lease_key in ipairs(lease_keys) do
    local tokens = redis.call('GET', lease_key)
    if tokens then
      local tokens_from_lease = tonumber(tokens)
      if tokens_from_lease then
        current_usage = current_usage + tokens_from_lease
        has_valid_leases = true
      else
        -- Remove lease with invalid token count
        redis.call('DEL', lease_key)
        redis.call('SREM', lease_set_key, lease_key)
      end
    else
      -- Lease key doesn't exist, remove from set
      redis.call('SREM', lease_set_key, lease_key)
    end
  end
  
  -- Refresh TTL on the set if there are valid leases (4x the lease TTL)
  if has_valid_leases then
    redis.call('EXPIRE', lease_set_key, expiration_seconds * 4)
  end
  
  return current_usage
LUA
    RELEASE_LEASE_SCRIPT = T.let(<<~LUA, T.untyped)
  local lease_key = KEYS[1]
  local queue_key = KEYS[2]
  local lease_set_key = KEYS[3]
  local token_count = tonumber(ARGV[1])
  local max_signals = tonumber(ARGV[2])
  
  -- Remove the lease
  redis.call('DEL', lease_key)
  -- Remove from the lease set
  redis.call('SREM', lease_set_key, lease_key)
  
  -- Signal waiting clients about the released tokens
  redis.call('LPUSH', queue_key, 'tokens:' .. token_count)
  
  -- Trim queue to prevent indefinite growth (atomic)
  redis.call('LTRIM', queue_key, 0, max_signals - 1)
  
  return 1
LUA
    GET_LEASE_SCRIPT_SHA = T.let(Digest::SHA1.hexdigest(GET_LEASE_SCRIPT), T.untyped)
    GET_USAGE_SCRIPT_SHA = T.let(Digest::SHA1.hexdigest(GET_USAGE_SCRIPT), T.untyped)
    RELEASE_LEASE_SCRIPT_SHA = T.let(Digest::SHA1.hexdigest(RELEASE_LEASE_SCRIPT), T.untyped)

    # sord warn - Redis wasn't able to be resolved to a constant in this project
    # sord warn - ConnectionPool wasn't able to be resolved to a constant in this project
    # sord omit - no YARD type given for "lease_expiration_seconds:", using untyped
    # Initialize the semaphore with a maximum capacity and required namespace.
    # 
    # _@param_ `capacity` — Maximum number of concurrent operations allowed
    # 
    # _@param_ `namespace` — Required namespace for Redis keys
    # 
    # _@param_ `redis` — Optional Redis client or connection pool (defaults to new Redis instance)
    # 
    # _@param_ `logger` — the logger
    sig do
      params(
        capacity: Integer,
        namespace: String,
        redis: T.nilable(T.any(Redis, ConnectionPool)),
        logger: Logger,
        lease_expiration_seconds: T.untyped
      ).void
    end
    def initialize(capacity, namespace, redis: nil, logger: CountingSemaphore::NullLogger, lease_expiration_seconds: LEASE_EXPIRATION_SECONDS); end

    # Acquires the given number of permits from this semaphore, blocking until all are available.
    # 
    # _@param_ `permits` — Number of permits to acquire (default: 1)
    # 
    # _@return_ — A lease object that must be passed to release()
    sig { params(permits: Integer).returns(CountingSemaphore::Lease) }
    def acquire(permits = 1); end

    # Releases a previously acquired lease, returning the permits to the semaphore.
    # 
    # _@param_ `lease` — The lease object returned by acquire() or try_acquire()
    sig { params(lease: CountingSemaphore::Lease).void }
    def release(lease); end

    # Acquires the given number of permits from this semaphore, only if all are available
    # at the time of invocation or within the timeout interval.
    # 
    # _@param_ `permits` — Number of permits to acquire (default: 1)
    # 
    # _@param_ `timeout` — Number of seconds to wait, or nil to return immediately (default: nil)
    # 
    # _@return_ — A lease object if successful, nil otherwise
    sig { params(permits: Integer, timeout: T.nilable(Numeric)).returns(T.nilable(CountingSemaphore::Lease)) }
    def try_acquire(permits = 1, timeout = nil); end

    # Returns the current number of permits available in this semaphore.
    # 
    # _@return_ — Number of available permits
    sig { returns(Integer) }
    def available_permits; end

    # Acquires and returns all permits that are immediately available.
    # Note: For distributed semaphores, this may not be perfectly accurate due to race conditions.
    # 
    # _@return_ — A lease for all available permits, or nil if none available
    sig { returns(T.nilable(CountingSemaphore::Lease)) }
    def drain_permits; end

    # sord omit - no YARD return type given, using untyped
    # Get current usage and active leases for debugging
    sig { returns(T.untyped) }
    def debug_info; end

    # sord warn - Redis wasn't able to be resolved to a constant in this project
    # sord warn - ConnectionPool wasn't able to be resolved to a constant in this project
    # Wraps a Redis client to support both ConnectionPool and bare Redis connections
    # 
    # _@param_ `redis` — The Redis client or connection pool
    # 
    # _@return_ — A wrapper that supports the `with` method
    sig { params(redis: T.any(Redis, ConnectionPool)).returns(Object) }
    def wrap_redis_client_with_pool(redis); end

    # Executes a block with a Redis connection from the pool
    # 
    # _@return_ — The result of the block
    sig { params(block: T.untyped).returns(T.untyped) }
    def with_redis(&block); end

    # Executes a Redis script with automatic fallback to EVAL on NOSCRIPT error
    # 
    # _@param_ `script_type` — The type of script (:get_lease, :release_lease, :get_usage)
    # 
    # _@param_ `keys` — Keys for the script
    # 
    # _@param_ `argv` — Arguments for the script
    # 
    # _@return_ — The result of the script execution
    sig { params(script_type: Symbol, keys: T::Array[T.untyped], argv: T::Array[T.untyped]).returns(T.untyped) }
    def execute_script(script_type, keys: [], argv: []); end

    # sord omit - no YARD type given for "permit_count", using untyped
    # sord omit - no YARD type given for "timeout_seconds:", using untyped
    # sord omit - no YARD return type given, using untyped
    sig { params(permit_count: T.untyped, timeout_seconds: T.untyped).returns(T.untyped) }
    def acquire_lease_internal(permit_count, timeout_seconds:); end

    # sord omit - no YARD type given for "permit_count", using untyped
    # sord omit - no YARD type given for "remaining_timeout", using untyped
    # sord omit - no YARD return type given, using untyped
    sig { params(permit_count: T.untyped, remaining_timeout: T.untyped).returns(T.untyped) }
    def wait_for_permits(permit_count, remaining_timeout); end

    # sord omit - no YARD type given for "token_count", using untyped
    # sord omit - no YARD return type given, using untyped
    sig { params(token_count: T.untyped).returns(T.untyped) }
    def attempt_lease_acquisition(token_count); end

    # sord omit - no YARD type given for "lease_key", using untyped
    # sord omit - no YARD type given for "token_count", using untyped
    # sord omit - no YARD return type given, using untyped
    sig { params(lease_key: T.untyped, token_count: T.untyped).returns(T.untyped) }
    def release_lease(lease_key, token_count); end

    # sord omit - no YARD return type given, using untyped
    sig { returns(T.untyped) }
    def get_current_usage; end

    # sord omit - no YARD return type given, using untyped
    sig { returns(T.untyped) }
    def generate_lease_id; end

    # Acquire a lease for the specified number of tokens and execute the block.
    # Blocks until sufficient resources are available.
    # 
    # _@param_ `token_count` — Number of tokens to acquire
    # 
    # _@param_ `timeout_seconds` — Maximum time to wait for lease acquisition (default: 30 seconds)
    # 
    # _@return_ — The result of the block
    sig { params(token_count: Integer, timeout_seconds: Integer, blk: T.proc.params(lease: T.nilable(CountingSemaphore::Lease)).void).returns(T.untyped) }
    def with_lease(token_count, timeout_seconds: 30, &blk); end

    # sord omit - no YARD type given for "token_count", using untyped
    # sord omit - no YARD type given for "timeout_seconds:", using untyped
    # sord omit - no YARD return type given, using untyped
    sig { params(token_count: T.untyped, timeout_seconds: T.untyped).returns(T.untyped) }
    def acquire_lease(token_count, timeout_seconds: 30); end

    # sord omit - no YARD type given for "token_count", using untyped
    # sord omit - no YARD type given for "remaining_timeout", using untyped
    # sord omit - no YARD return type given, using untyped
    sig { params(token_count: T.untyped, remaining_timeout: T.untyped).returns(T.untyped) }
    def wait_for_tokens(token_count, remaining_timeout); end

    # Get the current number of permits currently acquired.
    # Kept for backwards compatibility.
    # 
    # _@return_ — Number of permits currently in use
    sig { returns(Integer) }
    def currently_leased; end

    sig { returns(Integer) }
    attr_reader :capacity

    # Null pool for bare Redis connections that don't need connection pooling
    class NullPool
      # sord warn - Redis wasn't able to be resolved to a constant in this project
      # Creates a new NullPool wrapper around a Redis connection.
      # 
      # _@param_ `redis_connection` — The Redis connection to wrap
      sig { params(redis_connection: Redis).void }
      def initialize(redis_connection); end

      # Yields the wrapped Redis connection to the block.
      # Provides ConnectionPool-compatible interface.
      # 
      # _@return_ — The result of the block
      sig { params(block: T.untyped).returns(T.untyped) }
      def with(&block); end
    end

    # Custom exception for lease acquisition timeouts
    class LeaseTimeout < StandardError
      # sord omit - no YARD type given for "token_count", using untyped
      # sord omit - no YARD type given for "timeout_seconds", using untyped
      sig { params(token_count: T.untyped, timeout_seconds: T.untyped).void }
      def initialize(token_count, timeout_seconds); end
    end
  end

  # Module providing backwards-compatible with_lease method
  # Requires the including class to implement: acquire, release, capacity
  module WithLeaseSupport
    # Acquire a lease for the specified number of permits and execute the block.
    # Blocks until sufficient resources are available.
    # Kept for backwards compatibility - wraps acquire/release.
    # 
    # _@param_ `permit_count` — Number of permits to acquire (default: 1)
    # 
    # _@param_ `timeout_seconds` — Maximum time to wait for lease acquisition (default: 30 seconds)
    # 
    # _@return_ — The result of the block
    sig { params(permit_count: Integer, timeout_seconds: Integer, blk: T.proc.params(lease: T.nilable(CountingSemaphore::Lease)).void).returns(T.untyped) }
    def with_lease(permit_count = 1, timeout_seconds: 30, &blk); end

    # Get the current number of permits currently acquired.
    # Kept for backwards compatibility.
    # 
    # _@return_ — Number of permits currently in use
    sig { returns(Integer) }
    def currently_leased; end
  end
end
