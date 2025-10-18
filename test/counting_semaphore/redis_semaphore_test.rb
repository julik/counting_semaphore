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
      rescue CountingSemaphore::LeaseTimeout
        client2_timeout_raised = true
      end
    end

    # Wait for both clients to complete
    client1_thread.join
    client2_thread.join

    # Verify that client2 timed out as expected
    assert client2_timeout_raised, "Expected client2 to raise LeaseTimeout but it didn't"
  end

  def test_lease_timeout_includes_semaphore_reference
    capacity = 5
    namespace = "test_semaphore_#{SecureRandom.uuid}"
    mutex = Mutex.new
    condition = ConditionVariable.new
    client1_acquired = false
    exception = nil
    semaphore2 = nil

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
      rescue CountingSemaphore::LeaseTimeout => e
        exception = e
      end
    end

    # Wait for both clients to complete
    client1_thread.join
    client2_thread.join

    # Verify that the exception includes the semaphore reference
    refute_nil exception
    assert_equal semaphore2, exception.semaphore
    assert_equal 1, exception.token_count
    assert_equal 0.5, exception.timeout_seconds
  end

  def test_with_lease_uses_default_token_count_of_1
    semaphore = CountingSemaphore::RedisSemaphore.new(2, "test_namespace")
    result = nil

    # Should work with default token count (1)
    semaphore.with_lease do
      result = "success"
    end

    assert_equal "success", result
  end

  def test_with_lease_default_blocks_when_capacity_exceeded
    namespace = "test_semaphore_#{SecureRandom.uuid}"
    mutex = Mutex.new
    condition = ConditionVariable.new
    client1_acquired = false
    client2_timeout_raised = false

    # Client 1: Acquires all tokens using default (1) and waits for signal to release
    client1_thread = Thread.new do
      semaphore1 = CountingSemaphore::RedisSemaphore.new(
        1, # capacity
        namespace,
        redis: Redis.new(db: REDIS_DB),
        lease_expiration_seconds: 10
      )

      semaphore1.with_lease do  # Uses default token count of 1
        mutex.synchronize do
          client1_acquired = true
          condition.signal # Signal that client1 has acquired the token
        end

        # Wait for signal to release the lease
        mutex.synchronize do
          condition.wait(mutex, 2) # Wait up to 2 seconds for release signal
        end
      end
    end

    # Client 2: Tries to acquire 1 token with short timeout (should fail)
    client2_thread = Thread.new do
      # Wait for client1 to acquire the token
      mutex.synchronize do
        condition.wait(mutex, 1) until client1_acquired
      end

      semaphore2 = CountingSemaphore::RedisSemaphore.new(
        1, # capacity
        namespace,
        redis: Redis.new(db: REDIS_DB),
        lease_expiration_seconds: 10
      )

      begin
        semaphore2.with_lease(timeout_seconds: 0.5) do  # Uses default token count of 1
          # This should not execute
        end
      rescue CountingSemaphore::LeaseTimeout
        client2_timeout_raised = true
      end
    end

    # Wait for both clients to complete
    client1_thread.join
    client2_thread.join

    # Verify that client2 timed out as expected
    assert client2_timeout_raised, "Expected client2 to raise LeaseTimeout but it didn't"
  end

  def test_with_lease_yields_lease_to_block
    namespace = "test_semaphore_#{SecureRandom.uuid}"
    semaphore = CountingSemaphore::RedisSemaphore.new(5, namespace, redis: Redis.new(db: REDIS_DB))
    yielded_lease = nil

    result = semaphore.with_lease(3) do |lease|
      yielded_lease = lease
      "block result"
    end

    assert_equal "block result", result
    refute_nil yielded_lease
    assert_instance_of CountingSemaphore::Lease, yielded_lease
    assert_equal 3, yielded_lease.permits
    assert_equal semaphore, yielded_lease.semaphore
    assert_equal 5, semaphore.available_permits
  end

  def test_with_lease_yields_nil_for_zero_permits
    namespace = "test_semaphore_#{SecureRandom.uuid}"
    semaphore = CountingSemaphore::RedisSemaphore.new(5, namespace, redis: Redis.new(db: REDIS_DB))
    yielded_lease = :not_set

    semaphore.with_lease(0) do |lease|
      yielded_lease = lease
    end

    assert_nil yielded_lease
    assert_equal 5, semaphore.available_permits
  end

  def test_currently_leased_returns_zero_initially
    semaphore = CountingSemaphore::RedisSemaphore.new(5, "test_namespace")
    assert_equal 0, semaphore.currently_leased
  end

  def test_currently_leased_increases_during_lease
    semaphore = CountingSemaphore::RedisSemaphore.new(5, "test_namespace")
    usage_during_lease = nil

    semaphore.with_lease(2) do
      usage_during_lease = semaphore.currently_leased
    end

    assert_equal 2, usage_during_lease
    assert_equal 0, semaphore.currently_leased
  end

  def test_currently_leased_returns_to_zero_after_lease
    semaphore = CountingSemaphore::RedisSemaphore.new(3, "test_namespace")

    semaphore.with_lease(2) do
      assert_equal 2, semaphore.currently_leased
    end

    assert_equal 0, semaphore.currently_leased
  end

  def test_currently_leased_with_multiple_concurrent_leases
    namespace = "test_semaphore_#{SecureRandom.uuid}"
    semaphore = CountingSemaphore::RedisSemaphore.new(5, namespace)
    usage_values = []
    mutex = Mutex.new

    # Start multiple threads that will hold leases
    threads = []
    3.times do |i|
      threads << Thread.new do
        semaphore.with_lease(1) do
          mutex.synchronize { usage_values << semaphore.currently_leased }
          sleep(0.1) # Hold the lease briefly
        end
      end
    end

    threads.each(&:join)

    # Should have seen usage values of 1, 2, and 3 (or some combination)
    assert usage_values.any? { |usage| usage >= 1 }
    assert usage_values.any? { |usage| usage <= 3 }
    assert_equal 0, semaphore.currently_leased
  end

  def test_currently_leased_with_distributed_leases
    namespace = "test_semaphore_#{SecureRandom.uuid}"
    semaphore1 = CountingSemaphore::RedisSemaphore.new(5, namespace)
    semaphore2 = CountingSemaphore::RedisSemaphore.new(5, namespace)

    # Both semaphores should see the same usage since they share the namespace
    semaphore1.with_lease(2) do
      assert_equal 2, semaphore1.currently_leased
      assert_equal 2, semaphore2.currently_leased
    end

    assert_equal 0, semaphore1.currently_leased
    assert_equal 0, semaphore2.currently_leased
  end

  # Tests for concurrent-ruby compatible API

  def test_acquire_and_release_single_permit
    namespace = "test_semaphore_#{SecureRandom.uuid}"
    semaphore = CountingSemaphore::RedisSemaphore.new(3, namespace, redis: Redis.new(db: REDIS_DB))

    assert_equal 3, semaphore.available_permits

    lease = semaphore.acquire(1)
    assert_equal 2, semaphore.available_permits
    semaphore.release(lease)
    assert_equal 3, semaphore.available_permits
  end

  def test_acquire_and_release_multiple_permits
    namespace = "test_semaphore_#{SecureRandom.uuid}"
    semaphore = CountingSemaphore::RedisSemaphore.new(5, namespace, redis: Redis.new(db: REDIS_DB))

    lease = semaphore.acquire(3)
    assert_equal 2, semaphore.available_permits
    semaphore.release(lease)
    assert_equal 5, semaphore.available_permits
  end

  def test_acquire_defaults_to_one_permit
    namespace = "test_semaphore_#{SecureRandom.uuid}"
    semaphore = CountingSemaphore::RedisSemaphore.new(3, namespace, redis: Redis.new(db: REDIS_DB))

    lease = semaphore.acquire
    assert_equal 2, semaphore.available_permits

    semaphore.release(lease)
    assert_equal 3, semaphore.available_permits
  end

  test_with_timeout "acquire blocks until permits available" do
    namespace = "test_semaphore_#{SecureRandom.uuid}"
    completed_order = []
    mutex = Mutex.new

    # Thread 1: Acquires permits and holds them
    thread1 = Thread.new do
      semaphore1 = CountingSemaphore::RedisSemaphore.new(2, namespace, redis: Redis.new(db: REDIS_DB))
      lease1 = semaphore1.acquire(2)
      mutex.synchronize { completed_order << :thread1_acquired }
      sleep(0.2) # Hold briefly
      semaphore1.release(lease1)
      mutex.synchronize { completed_order << :thread1_released }
    end

    sleep(0.1) # Let thread1 acquire

    # Thread 2: Tries to acquire - should block until thread1 releases
    thread2 = Thread.new do
      semaphore2 = CountingSemaphore::RedisSemaphore.new(2, namespace, redis: Redis.new(db: REDIS_DB))
      mutex.synchronize { completed_order << :thread2_attempting }
      lease2 = semaphore2.acquire(1)
      mutex.synchronize { completed_order << :thread2_acquired }
      semaphore2.release(lease2)
    end

    thread1.join
    thread2.join

    # Thread2 should acquire after thread1 releases
    assert_equal [:thread1_acquired, :thread2_attempting, :thread1_released, :thread2_acquired], completed_order
  end

  def test_acquire_raises_error_for_invalid_permits
    namespace = "test_semaphore_#{SecureRandom.uuid}"
    semaphore = CountingSemaphore::RedisSemaphore.new(5, namespace, redis: Redis.new(db: REDIS_DB))

    assert_raises(ArgumentError) do
      semaphore.acquire(0)
    end

    assert_raises(ArgumentError) do
      semaphore.acquire(-1)
    end
  end

  def test_acquire_raises_error_for_permits_exceeding_capacity
    namespace = "test_semaphore_#{SecureRandom.uuid}"
    semaphore = CountingSemaphore::RedisSemaphore.new(3, namespace, redis: Redis.new(db: REDIS_DB))

    assert_raises(ArgumentError) do
      semaphore.acquire(5)
    end
  end

  def test_release_raises_error_for_invalid_lease
    namespace = "test_semaphore_#{SecureRandom.uuid}"
    semaphore = CountingSemaphore::RedisSemaphore.new(5, namespace, redis: Redis.new(db: REDIS_DB))

    assert_raises(NoMethodError) do
      semaphore.release("not a lease")
    end

    assert_raises(NoMethodError) do
      semaphore.release(nil)
    end
  end

  def test_release_raises_error_for_lease_from_different_semaphore
    namespace1 = "test_semaphore_#{SecureRandom.uuid}"
    namespace2 = "test_semaphore_#{SecureRandom.uuid}"
    semaphore1 = CountingSemaphore::RedisSemaphore.new(5, namespace1, redis: Redis.new(db: REDIS_DB))
    semaphore2 = CountingSemaphore::RedisSemaphore.new(5, namespace2, redis: Redis.new(db: REDIS_DB))

    lease = semaphore1.acquire(1)

    assert_raises(ArgumentError) do
      semaphore2.release(lease)
    end

    semaphore1.release(lease)
  end

  def test_try_acquire_succeeds_when_permits_available
    namespace = "test_semaphore_#{SecureRandom.uuid}"
    semaphore = CountingSemaphore::RedisSemaphore.new(3, namespace, redis: Redis.new(db: REDIS_DB))

    lease = semaphore.try_acquire(2)
    refute_nil lease
    assert_equal 1, semaphore.available_permits

    semaphore.release(lease)
  end

  def test_try_acquire_fails_when_permits_not_available
    namespace = "test_semaphore_#{SecureRandom.uuid}"
    semaphore = CountingSemaphore::RedisSemaphore.new(2, namespace, redis: Redis.new(db: REDIS_DB))

    lease1 = semaphore.acquire(2)
    lease2 = semaphore.try_acquire(1)
    assert_nil lease2

    semaphore.release(lease1)
  end

  def test_try_acquire_with_nil_timeout_returns_quickly
    namespace = "test_semaphore_#{SecureRandom.uuid}"
    semaphore = CountingSemaphore::RedisSemaphore.new(1, namespace, redis: Redis.new(db: REDIS_DB))

    lease1 = semaphore.acquire(1)
    start_time = Time.now

    lease2 = semaphore.try_acquire(1, nil)
    elapsed_time = Time.now - start_time

    assert_nil lease2
    assert elapsed_time < 0.5, "Should return quickly, took #{elapsed_time}s"

    semaphore.release(lease1)
  end

  test_with_timeout "try_acquire with timeout waits for permits" do
    namespace = "test_semaphore_#{SecureRandom.uuid}"

    # Thread 1: Holds the permit temporarily
    thread1 = Thread.new do
      semaphore1 = CountingSemaphore::RedisSemaphore.new(1, namespace, redis: Redis.new(db: REDIS_DB))
      lease1 = semaphore1.acquire(1)
      sleep(0.3)
      semaphore1.release(lease1)
    end

    sleep(0.1) # Let thread1 acquire

    # Thread 2: Tries to acquire with timeout - should eventually succeed
    lease2 = nil
    elapsed_time = 0
    thread2 = Thread.new do
      semaphore2 = CountingSemaphore::RedisSemaphore.new(1, namespace, redis: Redis.new(db: REDIS_DB))
      start_time = Time.now
      lease2 = semaphore2.try_acquire(1, 1.0)
      elapsed_time = Time.now - start_time
      semaphore2.release(lease2) if lease2
    end

    thread1.join
    thread2.join

    refute_nil lease2
    assert elapsed_time >= 0.2, "Should have waited for release"
    assert elapsed_time < 1.0, "Should not have waited full timeout"
  end

  def test_try_acquire_with_timeout_fails_when_timeout_exceeded
    namespace = "test_semaphore_#{SecureRandom.uuid}"
    semaphore = CountingSemaphore::RedisSemaphore.new(1, namespace, redis: Redis.new(db: REDIS_DB))

    lease1 = semaphore.acquire(1)
    start_time = Time.now
    lease2 = semaphore.try_acquire(1, 0.3)
    elapsed_time = Time.now - start_time

    assert_nil lease2
    assert elapsed_time >= 0.3, "Should have waited for timeout"

    semaphore.release(lease1)
  end

  def test_try_acquire_defaults_to_one_permit
    namespace = "test_semaphore_#{SecureRandom.uuid}"
    semaphore = CountingSemaphore::RedisSemaphore.new(3, namespace, redis: Redis.new(db: REDIS_DB))

    lease = semaphore.try_acquire
    refute_nil lease
    assert_equal 2, semaphore.available_permits

    semaphore.release(lease)
  end

  def test_try_acquire_raises_error_for_invalid_permits
    namespace = "test_semaphore_#{SecureRandom.uuid}"
    semaphore = CountingSemaphore::RedisSemaphore.new(5, namespace, redis: Redis.new(db: REDIS_DB))

    assert_raises(ArgumentError) do
      semaphore.try_acquire(0)
    end

    assert_raises(ArgumentError) do
      semaphore.try_acquire(-1)
    end
  end

  def test_available_permits_returns_correct_count
    namespace = "test_semaphore_#{SecureRandom.uuid}"
    semaphore = CountingSemaphore::RedisSemaphore.new(5, namespace, redis: Redis.new(db: REDIS_DB))

    assert_equal 5, semaphore.available_permits

    lease1 = semaphore.acquire(2)
    assert_equal 3, semaphore.available_permits

    lease2 = semaphore.acquire(1)
    assert_equal 2, semaphore.available_permits

    # Release all acquired permits
    semaphore.release(lease2)
    semaphore.release(lease1)
    assert_equal 5, semaphore.available_permits
  end

  test_with_timeout "available_permits with concurrent operations" do
    namespace = "test_semaphore_#{SecureRandom.uuid}"
    semaphore = CountingSemaphore::RedisSemaphore.new(5, namespace, redis: Redis.new(db: REDIS_DB))

    threads = 3.times.map do
      Thread.new do
        lease = semaphore.acquire(1)
        sleep(0.1)
        semaphore.release(lease)
      end
    end

    sleep(0.05) # Let threads acquire
    available = semaphore.available_permits

    # Should have 2 or fewer available (3 threads acquired)
    assert available <= 2, "Expected <= 2 available, got #{available}"

    threads.each(&:join)

    # All should be available now
    assert_equal 5, semaphore.available_permits
  end

  def test_drain_permits_acquires_all_available
    namespace = "test_semaphore_#{SecureRandom.uuid}"
    semaphore = CountingSemaphore::RedisSemaphore.new(5, namespace, redis: Redis.new(db: REDIS_DB))

    drained_lease = semaphore.drain_permits

    refute_nil drained_lease
    assert_equal 5, drained_lease.permits
    assert_equal 0, semaphore.available_permits

    # Release them back
    semaphore.release(drained_lease)
    assert_equal 5, semaphore.available_permits
  end

  def test_drain_permits_acquires_only_available
    namespace = "test_semaphore_#{SecureRandom.uuid}"
    semaphore = CountingSemaphore::RedisSemaphore.new(5, namespace, redis: Redis.new(db: REDIS_DB))

    lease1 = semaphore.acquire(2)
    drained_lease = semaphore.drain_permits

    refute_nil drained_lease
    assert_equal 3, drained_lease.permits
    assert_equal 0, semaphore.available_permits

    # Release them back
    semaphore.release(drained_lease)
    semaphore.release(lease1)
    assert_equal 5, semaphore.available_permits
  end

  def test_drain_permits_returns_nil_when_none_available
    namespace = "test_semaphore_#{SecureRandom.uuid}"
    semaphore = CountingSemaphore::RedisSemaphore.new(3, namespace, redis: Redis.new(db: REDIS_DB))

    lease = semaphore.acquire(3)
    drained_lease = semaphore.drain_permits

    assert_nil drained_lease
    assert_equal 0, semaphore.available_permits
    semaphore.release(lease)
  end

  test_with_timeout "acquire release maintain correct count under stress" do
    namespace = "test_semaphore_#{SecureRandom.uuid}"
    semaphore = CountingSemaphore::RedisSemaphore.new(10, namespace, redis: Redis.new(db: REDIS_DB))
    iterations = 10

    threads = 5.times.map do
      Thread.new do
        iterations.times do
          lease = semaphore.acquire(1)
          # No sleep - stress test
          semaphore.release(lease)
        end
      end
    end

    threads.each(&:join)

    # All permits should be available
    assert_equal 10, semaphore.available_permits
    assert_equal 0, semaphore.currently_leased
  end

  test_with_timeout "concurrent ruby api compatibility pattern" do
    namespace = "test_semaphore_#{SecureRandom.uuid}"
    semaphore = CountingSemaphore::RedisSemaphore.new(3, namespace, redis: Redis.new(db: REDIS_DB))
    results = []
    mutex = Mutex.new

    threads = 5.times.map do |i|
      Thread.new do
        if (lease = semaphore.try_acquire(1, 1.0))
          begin
            mutex.synchronize { results << i }
            sleep(0.1)
          ensure
            semaphore.release(lease)
          end
        end
      end
    end

    threads.each(&:join)

    # All threads should complete without hanging
    assert results.length > 0, "Expected at least some threads to succeed"
    assert results.length <= 5, "Expected no more threads than total (5)"
    assert_equal 3, semaphore.available_permits
  end

  test_with_timeout "distributed acquire and release across multiple instances" do
    namespace = "test_semaphore_#{SecureRandom.uuid}"
    semaphore1 = CountingSemaphore::RedisSemaphore.new(5, namespace, redis: Redis.new(db: REDIS_DB))
    semaphore2 = CountingSemaphore::RedisSemaphore.new(5, namespace, redis: Redis.new(db: REDIS_DB))

    # Acquire from first instance
    lease1 = semaphore1.acquire(2)
    assert_equal 3, semaphore1.available_permits
    assert_equal 3, semaphore2.available_permits

    # Acquire from second instance
    lease2 = semaphore2.acquire(2)
    assert_equal 1, semaphore1.available_permits
    assert_equal 1, semaphore2.available_permits

    # Release from first instance
    semaphore1.release(lease1)
    assert_equal 3, semaphore1.available_permits
    assert_equal 3, semaphore2.available_permits

    # Release from second instance
    semaphore2.release(lease2)
    assert_equal 5, semaphore1.available_permits
    assert_equal 5, semaphore2.available_permits
  end
end
