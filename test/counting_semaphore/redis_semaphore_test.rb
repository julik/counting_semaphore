require "test_helper"
require "counting_semaphore"
require "redis"

class RedisSemaphoreTest < Minitest::Test
  REDIS_DB = 2
  TIMEOUT_SECONDS = 3

  # Wrapper to ensure tests complete within 3 seconds
  def self.test_with_timeout(description, &blk)
    define_method("test_#{description}".gsub(/\s+/, "_")) do
      Timeout.timeout(3) do
        instance_exec(&blk)
      end
    rescue Timeout::Error
      flunk "Test timed out after 3 seconds"
    end
  end

  def test_initializes_with_correct_capacity
    semaphore = CountingSemaphore::RedisSemaphore.new(5, "test_namespace")
    assert_equal 5, semaphore.instance_variable_get(:@capacity)
  end

  def test_capacity_attribute_returns_the_initialized_capacity
    semaphore = CountingSemaphore::RedisSemaphore.new(10, "test_namespace")
    assert_equal 10, semaphore.capacity
  end

  def test_capacity_attribute_is_immutable
    semaphore = CountingSemaphore::RedisSemaphore.new(7, "test_namespace")
    assert_equal 7, semaphore.capacity

    # Verify that capacity cannot be modified directly
    assert_raises(NoMethodError) do
      semaphore.capacity = 5
    end
  end

  def test_raises_error_for_negative_capacity
    assert_raises(ArgumentError, "Capacity must be positive, got -3") do
      CountingSemaphore::RedisSemaphore.new(-3, "test_namespace")
    end
  end

  def test_raises_error_for_zero_capacity
    assert_raises(ArgumentError, "Capacity must be positive, got 0") do
      CountingSemaphore::RedisSemaphore.new(0, "test_namespace")
    end
  end

  def test_raises_error_for_negative_token_count
    semaphore = CountingSemaphore::RedisSemaphore.new(2, "test_namespace")

    assert_raises(ArgumentError, "Token count must be non-negative, got -1") do
      semaphore.with_lease(-1) do
        "should not reach here"
      end
    end
  end

  def test_allows_zero_token_count
    semaphore = CountingSemaphore::RedisSemaphore.new(2, "test_namespace")
    result = nil

    semaphore.with_lease(0) do
      result = "success"
    end

    assert_equal "success", result
  end

  def test_supports_connection_pool_redis_client
    # Create a mock ConnectionPool that responds to :with
    connection_pool = Class.new do
      def initialize(redis_connection)
        @redis_connection = redis_connection
      end

      def with(&block)
        block.call(@redis_connection)
      end
    end.new(Redis.new(db: REDIS_DB))

    semaphore = CountingSemaphore::RedisSemaphore.new(2, "test_namespace", redis: connection_pool)
    result = nil

    semaphore.with_lease(1) do
      result = "success"
    end

    assert_equal "success", result
  end

  def test_supports_bare_redis_connection
    # Test with a bare Redis connection (should be wrapped automatically)
    bare_redis = Redis.new(db: REDIS_DB)
    semaphore = CountingSemaphore::RedisSemaphore.new(2, "test_namespace", redis: bare_redis)
    result = nil

    semaphore.with_lease(1) do
      result = "success"
    end

    assert_equal "success", result
  end

  test_with_timeout "two clients with signaling using threads and condition variables" do
    results = []
    mutex = Mutex.new
    client1_acquired_condition = ConditionVariable.new
    release_condition = ConditionVariable.new

    # Create separate semaphores with separate Redis connections but same namespace
    shared_namespace = "test_semaphore_#{SecureRandom.uuid}"

    # Client 1: Acquires 8 tokens, then waits for signal to release
    client1_thread = Thread.new do
      semaphore1 = CountingSemaphore::RedisSemaphore.new(
        10, # capacity
        shared_namespace, # Same namespace so they can signal each other
        redis: Redis.new(db: REDIS_DB),
        lease_expiration_seconds: 1
      )

      semaphore1.with_lease(8) do
        results << "client1_acquired_8_tokens"

        # Signal that client1 has acquired the lease
        mutex.synchronize do
          results << "client1_signaling_acquisition"
          client1_acquired_condition.signal
        end

        # Wait for signal to release the lease
        mutex.synchronize do
          results << "client1_waiting_for_release_signal"
          release_condition.wait(mutex, 2) # Wait up to 2 seconds for release signal
          results << "client1_releasing_8_tokens"
        end
      end
      results << "client1_finished"
    end

    # Client 2: Waits for client1 to acquire, then attempts to acquire 5 tokens
    client2_thread = Thread.new do
      semaphore2 = CountingSemaphore::RedisSemaphore.new(
        10, # capacity
        shared_namespace, # Same namespace so they can signal each other
        redis: Redis.new(db: REDIS_DB),
        lease_expiration_seconds: 1
      )

      # Wait for client1 to acquire the lease
      mutex.synchronize do
        results << "client2_waiting_for_client1_acquisition"
        client1_acquired_condition.wait(mutex, 2) # Wait up to 2 seconds for client1 to acquire
        results << "client2_attempting_5_tokens"
      end

      semaphore2.with_lease(5, timeout_seconds: 2) do
        results << "client2_acquired_5_tokens"
        sleep 0.05
        results << "client2_releasing_5_tokens"
      end
      results << "client2_finished"
    end

    # Wait a bit for both clients to get into position
    sleep 0.1

    # Signal client1 to release the lease
    mutex.synchronize do
      results << "signaling_client1_to_release"
      release_condition.signal
    end

    # Wait for both clients to complete
    client1_thread.join
    client2_thread.join

    # Verify the sequence of events (order may vary due to timing)
    assert_includes results, "client1_acquired_8_tokens"
    assert_includes results, "client1_signaling_acquisition"
    assert_includes results, "client1_waiting_for_release_signal"
    assert_includes results, "client2_waiting_for_client1_acquisition"
    assert_includes results, "client2_attempting_5_tokens"
    assert_includes results, "signaling_client1_to_release"
    assert_includes results, "client1_releasing_8_tokens"
    assert_includes results, "client1_finished"
    assert_includes results, "client2_acquired_5_tokens"
    assert_includes results, "client2_releasing_5_tokens"
    assert_includes results, "client2_finished"
  end

  test_with_timeout "many clients all fighting for a resource" do
    capacity = 11
    lease = 4
    n_clients = 7
    operations = Set.new

    namespace = "test_semaphore_#{SecureRandom.uuid}"

    mux = Mutex.new
    threads = n_clients.times.map do |i|
      Thread.new do
        semaphore = CountingSemaphore::RedisSemaphore.new(
          capacity,
          namespace,
          redis: Redis.new(db: REDIS_DB),
          lease_expiration_seconds: 5
        )
        semaphore.with_lease(lease) do
          mux.synchronize { operations << "op from client #{i}" }
        end
      end
    end
    threads.map(&:join)
    assert_equal n_clients, operations.size
  end

  test_with_timeout "client timeout when semaphore is fully occupied" do
    capacity = 5
    namespace = "test_semaphore_#{SecureRandom.uuid}"
    mutex = Mutex.new
    condition = ConditionVariable.new
    client1_acquired = false
    client2_timeout_raised = false

    # Client 1: Acquires all 5 tokens and waits for signal to release
    client1_thread = Thread.new do
      semaphore1 = CountingSemaphore::RedisSemaphore.new(
        capacity,
        namespace,
        redis: Redis.new(db: REDIS_DB),
        lease_expiration_seconds: 10
      )

      semaphore1.with_lease(capacity) do
        mutex.synchronize do
          client1_acquired = true
          condition.signal # Signal that client1 has acquired all tokens
        end

        # Wait for signal to release the lease
        mutex.synchronize do
          condition.wait(mutex, 2) # Wait up to 2 seconds for release signal
        end
      end
    end

    # Client 2: Tries to acquire 1 token with short timeout (should fail)
    client2_thread = Thread.new do
      # Wait for client1 to acquire all tokens
      mutex.synchronize do
        condition.wait(mutex, 1) until client1_acquired
      end

      semaphore2 = CountingSemaphore::RedisSemaphore.new(
        capacity,
        namespace,
        redis: Redis.new(db: REDIS_DB),
        lease_expiration_seconds: 10
      )

      begin
        semaphore2.with_lease(1, timeout_seconds: 0.5) do
          # This should not execute
        end
      rescue CountingSemaphore::RedisSemaphore::LeaseTimeout
        client2_timeout_raised = true
      end
    end

    # Wait for both clients to complete
    client1_thread.join
    client2_thread.join

    # Verify that client2 timed out as expected
    assert client2_timeout_raised, "Expected client2 to raise LeaseTimeout but it didn't"
  end
end
