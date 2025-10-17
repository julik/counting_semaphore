# A distributed counting semaphore that allows up to N concurrent operations across multiple processes.
# Uses Redis for coordination and automatically handles lease expiration for crashed processes.
# Uses Redis Lua scripts for atomic operations to prevent race conditions.
require "digest"
require "securerandom"

module CountingSemaphore
  class RedisSemaphore
    LEASE_EXPIRATION_SECONDS = 5

    # Lua script for atomic lease acquisition
    # Returns: [success, lease_key, current_usage]
    # success: 1 if lease was acquired, 0 if no capacity
    # lease_key: the key of the acquired lease (if successful)
    # current_usage: current usage count after operation
    GET_LEASE_SCRIPT = <<~LUA
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

    # Lua script for getting current usage
    # Returns: current_usage (integer)
    GET_USAGE_SCRIPT = <<~LUA
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

    # Lua script for atomic lease release and signal
    # Returns: 1 (success)
    RELEASE_LEASE_SCRIPT = <<~LUA
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

    # Precomputed script SHAs
    GET_LEASE_SCRIPT_SHA = Digest::SHA1.hexdigest(GET_LEASE_SCRIPT)
    GET_USAGE_SCRIPT_SHA = Digest::SHA1.hexdigest(GET_USAGE_SCRIPT)
    RELEASE_LEASE_SCRIPT_SHA = Digest::SHA1.hexdigest(RELEASE_LEASE_SCRIPT)

    # @return [Integer]
    attr_reader :capacity

    # Initialize the semaphore with a maximum capacity and required namespace.
    #
    # @param capacity [Integer] Maximum number of concurrent operations allowed
    # @param namespace [String] Required namespace for Redis keys
    # @param redis [Redis, ConnectionPool] Optional Redis client or connection pool (defaults to new Redis instance)
    # @param logger [Logger] the logger
    # @raise [ArgumentError] if capacity is not positive
    def initialize(capacity, namespace, redis: nil, logger: CountingSemaphore::NullLogger, lease_expiration_seconds: LEASE_EXPIRATION_SECONDS)
      raise ArgumentError, "Capacity must be positive, got #{capacity}" unless capacity > 0

      # Require Redis only when SharedSemaphore is used
      require "redis" unless defined?(Redis)

      @capacity = capacity
      @redis_connection_pool = wrap_redis_client_with_pool(redis || Redis.new)
      @namespace = namespace
      @lease_expiration_seconds = lease_expiration_seconds
      @logger = logger

      # Scripts are precomputed and will be loaded on-demand if needed
    end

    # Null pool for bare Redis connections that don't need connection pooling
    class NullPool
      def initialize(redis_connection)
        @redis_connection = redis_connection
      end

      def with(&block)
        block.call(@redis_connection)
      end
    end

    # Acquire a lease for the specified number of tokens and execute the block.
    # Blocks until sufficient resources are available.
    #
    # @param token_count [Integer] Number of tokens to acquire
    # @param timeout_seconds [Integer] Maximum time to wait for lease acquisition (default: 30 seconds)
    # @yield The block to execute while holding the lease
    # @return The result of the block
    # @raise [ArgumentError] if token_count is negative or exceeds the semaphore capacity
    # @raise [LeaseTimeout] if lease cannot be acquired within timeout
    def with_lease(token_count = 1, timeout_seconds: 30)
      raise ArgumentError, "Token count must be non-negative, got #{token_count}" if token_count < 0
      if token_count > @capacity
        raise ArgumentError, "Cannot lease #{token_count} slots as we only allow #{@capacity}"
      end

      # Handle zero tokens case - no Redis coordination needed
      return yield if token_count.zero?

      lease_key = acquire_lease(token_count, timeout_seconds: timeout_seconds)
      begin
        @logger.debug "🚦Leased #{token_count} tokens with lease #{lease_key}"
        yield
      ensure
        release_lease(lease_key, token_count)
      end
    end

    # Get the current number of tokens currently leased
    #
    # @return [Integer] Number of tokens currently in use
    def currently_leased
      get_current_usage
    end

    # Get current usage and active leases for debugging
    def debug_info
      usage = get_current_usage
      lease_set_key = "#{@namespace}:lease_set"
      lease_keys = with_redis { |redis| redis.smembers(lease_set_key) }
      active_leases = []

      lease_keys.each do |lease_key|
        tokens = with_redis { |redis| redis.get(lease_key) }
        next unless tokens

        active_leases << {
          key: lease_key,
          tokens: tokens.to_i
        }
      end

      {
        usage: usage,
        capacity: @capacity,
        available: @capacity - usage,
        active_leases: active_leases
      }
    end

    private

    # Wraps a Redis client to support both ConnectionPool and bare Redis connections
    # @param redis [Redis, ConnectionPool] The Redis client or connection pool
    # @return [Object] A wrapper that supports the `with` method
    def wrap_redis_client_with_pool(redis)
      # If it's already a ConnectionPool, return it as-is
      return redis if redis.respond_to?(:with)

      # For bare Redis connections, wrap in a NullPool
      NullPool.new(redis)
    end

    # Executes a block with a Redis connection from the pool
    # @yield [redis] The Redis connection
    # @return The result of the block
    def with_redis(&block)
      @redis_connection_pool.with(&block)
    end

    # Executes a Redis script with automatic fallback to EVAL on NOSCRIPT error
    # @param script_type [Symbol] The type of script (:get_lease, :release_lease, :get_usage)
    # @param keys [Array] Keys for the script
    # @param argv [Array] Arguments for the script
    # @return The result of the script execution
    def execute_script(script_type, keys: [], argv: [])
      script_sha, script_body = case script_type
      when :get_lease then [GET_LEASE_SCRIPT_SHA, GET_LEASE_SCRIPT]
      when :release_lease then [RELEASE_LEASE_SCRIPT_SHA, RELEASE_LEASE_SCRIPT]
      when :get_usage then [GET_USAGE_SCRIPT_SHA, GET_USAGE_SCRIPT]
      else raise ArgumentError, "Unknown script type: #{script_type}"
      end

      with_redis do |redis|
        redis.evalsha(script_sha, keys: keys, argv: argv)
      end
    rescue Redis::CommandError => e
      if e.message.include?("NOSCRIPT")
        @logger.debug "🚦Script not found, using EVAL: #{e.message}"
        # Fall back to EVAL with the script body
        with_redis do |redis|
          redis.eval(script_body, keys: keys, argv: argv)
        end
      else
        raise
      end
    end

    def acquire_lease(token_count, timeout_seconds: 30)
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      loop do
        # Check if we've exceeded the timeout using monotonic time
        elapsed_time = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
        if elapsed_time >= timeout_seconds
          raise CountingSemaphore::LeaseTimeout.new(token_count, timeout_seconds, self)
        end

        # Try optimistic acquisition first
        lease_key = attempt_lease_acquisition(token_count)
        return lease_key if lease_key

        # If failed, wait for signals with timeout
        lease_key = wait_for_tokens(token_count, timeout_seconds - elapsed_time)
        return lease_key if lease_key
      end
    end

    def wait_for_tokens(token_count, remaining_timeout)
      # Ensure minimum timeout to prevent infinite blocking
      # BLPOP with timeout 0 blocks forever, so we need at least a small positive timeout
      minimum_timeout = 0.1
      if remaining_timeout <= minimum_timeout
        @logger.debug "🚦Remaining timeout (#{remaining_timeout}s) too small, not waiting"
        return nil
      end

      # Block with timeout (longer than lease expiration to handle stale leases)
      # But don't exceed the remaining timeout
      timeout = [@lease_expiration_seconds + 2, remaining_timeout].min
      @logger.debug "🚦Unable to lease #{token_count}, waiting for signals (timeout: #{timeout}s)"

      with_redis { |redis| redis.blpop("#{@namespace}:waiting_queue", timeout: timeout.to_f) }

      # Try to acquire after any signal or timeout
      lease_key = attempt_lease_acquisition(token_count)
      if lease_key
        return lease_key
      end

      # If still can't acquire, return nil to continue the loop in acquire_lease
      @logger.debug "🚦Still unable to lease #{token_count} after signal/timeout, continuing to wait"
      nil
    end

    def attempt_lease_acquisition(token_count)
      lease_id = generate_lease_id
      lease_key = "#{@namespace}:leases:#{lease_id}"
      lease_set_key = "#{@namespace}:lease_set"

      # Use Lua script for atomic lease acquisition
      result = execute_script(
        :get_lease,
        keys: [lease_key, lease_set_key],
        argv: [
          @capacity.to_s,
          token_count.to_s,
          @lease_expiration_seconds.to_s
        ]
      )

      success, full_lease_key, current_usage = result

      if success == 1
        # Extract just the lease ID from the full key for return value
        lease_id = full_lease_key.split(":").last
        @logger.debug "🚦Acquired lease #{lease_id}, current usage: #{current_usage}/#{@capacity}"
        lease_id
      else
        @logger.debug "🚦No capacity available, current usage: #{current_usage}/#{@capacity}"
        nil
      end
    end

    def release_lease(lease_key, token_count)
      return if lease_key.nil?

      full_lease_key = "#{@namespace}:leases:#{lease_key}"
      queue_key = "#{@namespace}:waiting_queue"
      lease_set_key = "#{@namespace}:lease_set"

      # Use Lua script for atomic lease release and signal
      execute_script(
        :release_lease,
        keys: [full_lease_key, queue_key, lease_set_key],
        argv: [
          token_count.to_s,
          (@capacity * 2).to_s
        ]
      )

      @logger.debug "🚦Returned #{token_count} leased tokens (lease: #{lease_key}) and signaled waiting clients"
    end

    def get_current_usage
      lease_set_key = "#{@namespace}:lease_set"

      # Use the dedicated usage script that calculates current usage
      execute_script(
        :get_usage,
        keys: [lease_set_key],
        argv: [@lease_expiration_seconds.to_s]
      )
    end

    def generate_lease_id
      SecureRandom.uuid
    end
  end
end
