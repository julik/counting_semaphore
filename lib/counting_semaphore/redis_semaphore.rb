# frozen_string_literal: true

# A distributed counting semaphore that allows up to N concurrent operations across multiple processes.
# Uses Redis for coordination and automatically handles lease expiration for crashed processes.
# Uses Redis Lua scripts for atomic operations to prevent race conditions.
# API compatible with concurrent-ruby's Semaphore class.
require "digest"
require "securerandom"

module CountingSemaphore
  class RedisSemaphore
    include WithLeaseSupport

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
      local permit_count = tonumber(ARGV[2])
      local expiration_seconds = tonumber(ARGV[3])
      
      -- Get all active leases from the set and calculate current usage
      local lease_keys = redis.call('SMEMBERS', lease_set_key)
      local current_usage = 0
      local valid_leases = {}
      
      for i, key in ipairs(lease_keys) do
        local permits = redis.call('GET', key)
        if permits then
          local permits_from_lease = tonumber(permits)
          if permits_from_lease then
            current_usage = current_usage + permits_from_lease
            table.insert(valid_leases, key)
          else
            -- Remove lease with invalid permit count
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
      if available >= permit_count then
        -- Set lease with TTL (value is just the permit count)
        redis.call('SETEX', lease_key, expiration_seconds, permit_count)
        -- Add lease key to the set
        redis.call('SADD', lease_set_key, lease_key)
        -- Set TTL on the set (4x the lease TTL to ensure cleanup)
        redis.call('EXPIRE', lease_set_key, expiration_seconds * 4)
        
        return {1, lease_key, current_usage + permit_count}
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
        local permits = redis.call('GET', lease_key)
        if permits then
          local permits_from_lease = tonumber(permits)
          if permits_from_lease then
            current_usage = current_usage + permits_from_lease
            has_valid_leases = true
          else
            -- Remove lease with invalid permit count
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
      local permit_count = tonumber(ARGV[1])
      local max_signals = tonumber(ARGV[2])
      
      -- Remove the lease
      redis.call('DEL', lease_key)
      -- Remove from the lease set
      redis.call('SREM', lease_set_key, lease_key)
      
      -- Signal waiting clients about the released permits
      redis.call('LPUSH', queue_key, 'permits:' .. permit_count)
      
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
    # @param capacity [Integer] Maximum number of concurrent operations allowed (also called permits)
    # @param namespace [String] Required namespace for Redis keys
    # @param redis [Redis, ConnectionPool] Optional Redis client or connection pool (defaults to new Redis instance)
    # @param logger [Logger] the logger
    # @raise [ArgumentError] if capacity is not positive
    def initialize(capacity, namespace, redis: nil, logger: CountingSemaphore::NullLogger, lease_expiration_seconds: LEASE_EXPIRATION_SECONDS)
      raise ArgumentError, "Capacity must be positive, got #{capacity}" unless capacity > 0

      # Require Redis only when RedisSemaphore is used
      require "redis" unless defined?(Redis)

      @capacity = capacity
      @redis_connection_pool = wrap_redis_client_with_pool(redis || Redis.new)
      @namespace = namespace
      @lease_expiration_seconds = lease_expiration_seconds
      @logger = logger

      # Scripts are precomputed and will be loaded on-demand if needed
    end

    # Null pool for bare Redis connections that don't need connection pooling.
    # Provides a compatible interface with ConnectionPool for bare Redis instances.
    class NullPool
      # Creates a new NullPool wrapper around a Redis connection.
      #
      # @param redis_connection [Redis] The Redis connection to wrap
      def initialize(redis_connection)
        @redis_connection = redis_connection
      end

      # Yields the wrapped Redis connection to the block.
      # Provides ConnectionPool-compatible interface.
      #
      # @yield [redis] The Redis connection
      # @return The result of the block
      def with(&block)
        block.call(@redis_connection)
      end
    end

    # Acquires the given number of permits from this semaphore, blocking until all are available.
    #
    # @param permits [Integer] Number of permits to acquire (default: 1)
    # @return [CountingSemaphore::Lease] A lease object that must be passed to release()
    # @raise [ArgumentError] if permits is not an integer or is less than one
    def acquire(permits = 1)
      raise ArgumentError, "Permits must be at least 1, got #{permits}" if permits < 1
      if permits > @capacity
        raise ArgumentError, "Cannot acquire #{permits} permits as capacity is only #{@capacity}"
      end

      lease_key = acquire_lease_internal(permits, timeout_seconds: nil)
      @logger.debug { "Acquired #{permits} permits with lease #{lease_key}" }

      CountingSemaphore::Lease.new(
        semaphore: self,
        id: lease_key,
        permits: permits
      )
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

      release_lease(lease.id, lease.permits)
      nil
    end

    # Acquires the given number of permits from this semaphore, only if all are available
    # at the time of invocation or within the timeout interval.
    #
    # @param permits [Integer] Number of permits to acquire (default: 1)
    # @param timeout [Numeric, nil] Number of seconds to wait, or nil to return immediately (default: nil).
    #   The timeout value will be rounded up to the nearest whole second due to Redis BLPOP limitations.
    # @return [CountingSemaphore::Lease, nil] A lease object if successful, nil otherwise
    # @raise [ArgumentError] if permits is not an integer or is less than one
    def try_acquire(permits = 1, timeout: nil)
      raise ArgumentError, "Permits must be at least 1, got #{permits}" if permits < 1
      if permits > @capacity
        return nil
      end

      timeout_seconds = timeout.nil? ? 0.1 : timeout
      begin
        lease_key = acquire_lease_internal(permits, timeout_seconds: timeout_seconds)
        @logger.debug { "Acquired #{permits} permits (try) with lease #{lease_key}" }

        CountingSemaphore::Lease.new(
          semaphore: self,
          id: lease_key,
          permits: permits
        )
      rescue CountingSemaphore::LeaseTimeout
        nil
      end
    end

    # Returns the current number of permits available in this semaphore.
    #
    # @return [Integer] Number of available permits
    def available_permits
      current_usage = get_current_usage
      @capacity - current_usage
    end

    # Acquires and returns all permits that are immediately available.
    # Note: For distributed semaphores, this may not be perfectly accurate due to race conditions.
    #
    # @return [CountingSemaphore::Lease, nil] A lease for all available permits, or nil if none available
    def drain_permits
      available = available_permits
      return nil if available <= 0

      # Try to acquire all available permits
      try_acquire(available, timeout: 0.1)
    end

    # Returns debugging information about the current state of the semaphore.
    # Includes current usage, capacity, available permits, and details about active leases.
    #
    # @return [Hash] A hash containing :usage, :capacity, :available, and :active_leases
    # @example
    #   info = semaphore.debug_info
    #   puts "Usage: #{info[:usage]}/#{info[:capacity]}"
    #   info[:active_leases].each { |lease| puts "Lease: #{lease[:key]} - #{lease[:permits]} permits" }
    def debug_info
      usage = get_current_usage
      lease_set_key = "#{@namespace}:lease_set"
      lease_keys = with_redis { |redis| redis.smembers(lease_set_key) }
      active_leases = []

      lease_keys.each do |lease_key|
        permits = with_redis { |redis| redis.get(lease_key) }
        next unless permits

        active_leases << {
          key: lease_key,
          permits: permits.to_i
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
        @logger.debug { "Script not found, using EVAL: #{e.message}" }
        # Fall back to EVAL with the script body
        with_redis do |redis|
          redis.eval(script_body, keys: keys, argv: argv)
        end
      else
        raise
      end
    end

    def acquire_lease_internal(permit_count, timeout_seconds:)
      # If timeout is nil, wait indefinitely (for acquire method)
      if timeout_seconds.nil?
        loop do
          lease_key = attempt_lease_acquisition(permit_count)
          return lease_key if lease_key

          # Wait for signals indefinitely
          wait_for_permits(permit_count, nil)
        end
      else
        # Wait with timeout (for with_lease and try_acquire)
        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        loop do
          # Check if we've exceeded the timeout using monotonic time
          elapsed_time = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
          if elapsed_time >= timeout_seconds
            raise CountingSemaphore::LeaseTimeout.new(permit_count, timeout_seconds, self)
          end

          # Try optimistic acquisition first
          lease_key = attempt_lease_acquisition(permit_count)
          return lease_key if lease_key

          # If failed, wait for signals with timeout
          lease_key = wait_for_permits(permit_count, timeout_seconds - elapsed_time)
          return lease_key if lease_key
        end
      end
    end

    def wait_for_permits(permit_count, remaining_timeout)
      # If remaining_timeout is nil, wait indefinitely
      if remaining_timeout.nil?
        timeout = @lease_expiration_seconds + 2
        @logger.debug { "Unable to acquire #{permit_count} permits, waiting for signals (indefinite)" }
      else
        # Ensure minimum timeout to prevent infinite blocking
        # BLPOP with timeout 0 blocks forever, so we need at least a small positive timeout
        minimum_timeout = 0.1
        if remaining_timeout <= minimum_timeout
          @logger.debug { "Remaining timeout (#{remaining_timeout}s) too small, not waiting" }
          return nil
        end

        # Block with timeout (longer than lease expiration to handle stale leases)
        # But don't exceed the remaining timeout
        timeout = [@lease_expiration_seconds + 2, remaining_timeout].min
        @logger.debug { "Unable to acquire #{permit_count} permits, waiting for signals (timeout: #{timeout}s)" }
      end

      with_redis { |redis| redis.blpop("#{@namespace}:waiting_queue", timeout: timeout.to_f) }

      # Try to acquire after any signal or timeout
      lease_key = attempt_lease_acquisition(permit_count)
      if lease_key
        return lease_key
      end

      # If still can't acquire, return nil to continue the loop
      @logger.debug { "Still unable to acquire #{permit_count} permits after signal/timeout, continuing to wait" }
      nil
    end

    def attempt_lease_acquisition(permit_count)
      lease_id = generate_lease_id
      lease_key = "#{@namespace}:leases:#{lease_id}"
      lease_set_key = "#{@namespace}:lease_set"

      # Use Lua script for atomic lease acquisition
      result = execute_script(
        :get_lease,
        keys: [lease_key, lease_set_key],
        argv: [
          @capacity.to_s,
          permit_count.to_s,
          @lease_expiration_seconds.to_s
        ]
      )

      success, full_lease_key, current_usage = result

      if success == 1
        # Extract just the lease ID from the full key for return value
        lease_id = full_lease_key.split(":").last
        @logger.debug { "Acquired lease #{lease_id}, current usage: #{current_usage}/#{@capacity}" }
        lease_id
      else
        @logger.debug { "No capacity available, current usage: #{current_usage}/#{@capacity}" }
        nil
      end
    end

    def release_lease(lease_key, permit_count)
      return if lease_key.nil?

      full_lease_key = "#{@namespace}:leases:#{lease_key}"
      queue_key = "#{@namespace}:waiting_queue"
      lease_set_key = "#{@namespace}:lease_set"

      # Use Lua script for atomic lease release and signal
      execute_script(
        :release_lease,
        keys: [full_lease_key, queue_key, lease_set_key],
        argv: [
          permit_count.to_s,
          (@capacity * 2).to_s
        ]
      )

      @logger.debug { "Returned #{permit_count} leased permits (lease: #{lease_key}) and signaled waiting clients" }
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
