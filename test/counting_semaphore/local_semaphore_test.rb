require "test_helper"
require "counting_semaphore"

class LocalSemaphoreTest < Minitest::Test
  def test_initializes_with_correct_capacity
    semaphore = CountingSemaphore::LocalSemaphore.new(5)
    assert_equal 5, semaphore.instance_variable_get(:@capacity)
  end

  def test_capacity_attribute_returns_the_initialized_capacity
    semaphore = CountingSemaphore::LocalSemaphore.new(10)
    assert_equal 10, semaphore.capacity
  end

  def test_capacity_attribute_is_immutable
    semaphore = CountingSemaphore::LocalSemaphore.new(7)
    assert_equal 7, semaphore.capacity

    # Verify that capacity cannot be modified directly
    assert_raises(NoMethodError) do
      semaphore.capacity = 5
    end
  end

  def test_raises_error_for_negative_capacity
    assert_raises(ArgumentError, "Capacity must be positive, got -3") do
      CountingSemaphore::LocalSemaphore.new(-3)
    end
  end

  def test_raises_error_for_zero_capacity
    assert_raises(ArgumentError, "Capacity must be positive, got 0") do
      CountingSemaphore::LocalSemaphore.new(0)
    end
  end

  def test_allows_operations_within_capacity
    semaphore = CountingSemaphore::LocalSemaphore.new(2)
    result = nil

    semaphore.with_lease(1) do
      result = "success"
    end

    assert_equal "success", result
  end

  def test_blocks_when_capacity_exceeded
    semaphore = CountingSemaphore::LocalSemaphore.new(1)
    start_time = Time.now
    completed = false

    # Start a thread that will hold the semaphore
    thread1 = Thread.new do
      semaphore.with_lease(1) do
        sleep(0.1) # Hold the semaphore briefly
        "thread1"
      end
    end

    # Start another thread that should block
    thread2 = Thread.new do
      semaphore.with_lease(1) do
        completed = true
        "thread2"
      end
    end

    thread1.join
    thread2.join

    # The second thread should have completed after the first released
    assert completed
    assert (Time.now - start_time) >= 0.1
  end

  def test_raises_error_when_requesting_more_tokens_than_capacity
    semaphore = CountingSemaphore::LocalSemaphore.new(2)

    assert_raises(ArgumentError) do
      semaphore.with_lease(3) do
        "should not reach here"
      end
    end
  end

  def test_raises_error_for_negative_token_count
    semaphore = CountingSemaphore::LocalSemaphore.new(2)

    assert_raises(ArgumentError, "Token count must be non-negative, got -1") do
      semaphore.with_lease(-1) do
        "should not reach here"
      end
    end
  end

  def test_allows_zero_token_count
    semaphore = CountingSemaphore::LocalSemaphore.new(2)
    result = nil

    semaphore.with_lease(0) do
      result = "success"
    end

    assert_equal "success", result
  end

  def test_properly_releases_tokens_after_block_completion
    semaphore = CountingSemaphore::LocalSemaphore.new(1)
    results = []

    # First operation should succeed immediately
    semaphore.with_lease(1) do
      results << "first"
    end

    # Second operation should also succeed immediately (tokens were released)
    semaphore.with_lease(1) do
      results << "second"
    end

    assert_equal ["first", "second"], results
  end

  def test_handles_exceptions_and_still_releases_tokens
    semaphore = CountingSemaphore::LocalSemaphore.new(1)
    results = []

    # First operation succeeds
    semaphore.with_lease(1) do
      results << "first"
    end

    # Second operation should fail but still release tokens
    assert_raises(RuntimeError) do
      semaphore.with_lease(1) do
        results << "second"
        raise "test error"
      end
    end

    # Third operation should succeed (tokens were released despite exception)
    semaphore.with_lease(1) do
      results << "third"
    end

    assert_equal ["first", "second", "third"], results
  end

  def test_supports_multiple_tokens_per_lease
    semaphore = CountingSemaphore::LocalSemaphore.new(3)
    results = []

    # Should be able to lease 2 tokens at once
    semaphore.with_lease(2) do
      results << "two_tokens"
    end

    # Should be able to lease 1 more token
    semaphore.with_lease(1) do
      results << "one_token"
    end

    assert_equal ["two_tokens", "one_token"], results
  end

  def test_with_lease_accepts_timeout_parameter
    semaphore = CountingSemaphore::LocalSemaphore.new(1)

    # Test that timeout parameter is accepted
    result = semaphore.with_lease(1, timeout: 5) do
      "success"
    end

    assert_equal "success", result
  end

  def test_with_lease_raises_timeout_error_when_timeout_is_exceeded
    semaphore = CountingSemaphore::LocalSemaphore.new(1)

    # Fill the semaphore
    semaphore.with_lease(1) do
      # Try to acquire another token with a very short timeout
      assert_raises(CountingSemaphore::LeaseTimeout) do
        semaphore.with_lease(1, timeout: 0.1) do
          "should not reach here"
        end
      end
    end
  end

  def test_lease_timeout_includes_semaphore_reference
    semaphore = CountingSemaphore::LocalSemaphore.new(1)
    exception = nil

    # Fill the semaphore
    semaphore.with_lease(1) do
      # Try to acquire another token with a very short timeout

      semaphore.with_lease(1, timeout: 0.1) do
        "should not reach here"
      end
    rescue CountingSemaphore::LeaseTimeout => e
      exception = e
    end

    refute_nil exception
    assert_equal semaphore, exception.semaphore
    assert_equal 1, exception.token_count
    assert_equal 0.1, exception.timeout_seconds
  end

  def test_with_lease_uses_default_token_count_of_1
    semaphore = CountingSemaphore::LocalSemaphore.new(2)
    result = nil

    # Should work with default token count (1)
    semaphore.with_lease do
      result = "success"
    end

    assert_equal "success", result
  end

  def test_with_lease_default_blocks_when_capacity_exceeded
    semaphore = CountingSemaphore::LocalSemaphore.new(1)
    start_time = Time.now
    completed = false

    # Start a thread that will hold the semaphore
    thread1 = Thread.new do
      semaphore.with_lease do  # Uses default token count of 1
        sleep(0.1) # Hold the semaphore briefly
        "thread1"
      end
    end

    # Start another thread that should block
    thread2 = Thread.new do
      semaphore.with_lease do  # Uses default token count of 1
        completed = true
        "thread2"
      end
    end

    thread1.join
    thread2.join

    # The second thread should have completed after the first released
    assert completed
    assert (Time.now - start_time) >= 0.1
  end

  def test_with_lease_yields_lease_to_block
    semaphore = CountingSemaphore::LocalSemaphore.new(5)
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
    semaphore = CountingSemaphore::LocalSemaphore.new(5)
    yielded_lease = :not_set

    semaphore.with_lease(0) do |lease|
      yielded_lease = lease
    end

    assert_nil yielded_lease
    assert_equal 5, semaphore.available_permits
  end

  def test_currently_leased_returns_zero_initially
    semaphore = CountingSemaphore::LocalSemaphore.new(5)
    assert_equal 0, semaphore.currently_leased
  end

  def test_currently_leased_increases_during_lease
    semaphore = CountingSemaphore::LocalSemaphore.new(5)
    usage_during_lease = nil

    semaphore.with_lease(2) do
      usage_during_lease = semaphore.currently_leased
    end

    assert_equal 2, usage_during_lease
    assert_equal 0, semaphore.currently_leased
  end

  def test_currently_leased_returns_to_zero_after_lease
    semaphore = CountingSemaphore::LocalSemaphore.new(3)

    semaphore.with_lease(2) do
      assert_equal 2, semaphore.currently_leased
    end

    assert_equal 0, semaphore.currently_leased
  end

  def test_currently_leased_with_multiple_concurrent_leases
    semaphore = CountingSemaphore::LocalSemaphore.new(5)
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

  # Tests for Lease-based API

  def test_acquire_returns_lease_object
    semaphore = CountingSemaphore::LocalSemaphore.new(3)

    lease = semaphore.acquire(1)
    assert_instance_of CountingSemaphore::Lease, lease
    assert_equal semaphore, lease.semaphore
    assert_equal 1, lease.permits
    refute_nil lease.id
    semaphore.release(lease)
  end

  def test_acquire_and_release_single_permit
    semaphore = CountingSemaphore::LocalSemaphore.new(3)

    assert_equal 3, semaphore.available_permits

    lease = semaphore.acquire(1)
    assert_equal 2, semaphore.available_permits
    semaphore.release(lease)
    assert_equal 3, semaphore.available_permits
  end

  def test_acquire_and_release_multiple_permits
    semaphore = CountingSemaphore::LocalSemaphore.new(5)

    lease = semaphore.acquire(3)
    assert_equal 2, semaphore.available_permits
    semaphore.release(lease)
    assert_equal 5, semaphore.available_permits
  end

  def test_acquire_defaults_to_one_permit
    semaphore = CountingSemaphore::LocalSemaphore.new(3)

    lease = semaphore.acquire
    assert_equal 2, semaphore.available_permits

    semaphore.release(lease)
    assert_equal 3, semaphore.available_permits
  end

  def test_acquire_blocks_until_permits_available
    semaphore = CountingSemaphore::LocalSemaphore.new(2)
    completed_order = []
    mutex = Mutex.new

    # Fill the semaphore
    lease = semaphore.acquire(2)
    thread1 = Thread.new do
      lease = semaphore.acquire(1)
      mutex.synchronize { completed_order << :thread1 }
      semaphore.release(lease)
    end

    sleep(0.1) # Give thread1 time to block

    thread2 = Thread.new do
      mutex.synchronize { completed_order << :main_release }
      semaphore.release(lease)
    end

    thread1.join
    thread2.join

    # Thread1 should complete after the release
    assert_equal [:main_release, :thread1], completed_order
  end

  def test_acquire_raises_error_for_invalid_permits
    semaphore = CountingSemaphore::LocalSemaphore.new(5)

    assert_raises(ArgumentError) do
      semaphore.acquire(0)
    end

    assert_raises(ArgumentError) do
      semaphore.acquire(-1)
    end
  end

  def test_acquire_raises_error_for_permits_exceeding_capacity
    semaphore = CountingSemaphore::LocalSemaphore.new(3)

    assert_raises(ArgumentError) do
      semaphore.acquire(5)
    end
  end

  def test_release_raises_error_for_invalid_lease
    semaphore = CountingSemaphore::LocalSemaphore.new(5)

    assert_raises(NoMethodError) do
      semaphore.release("not a lease")
    end

    assert_raises(NoMethodError) do
      semaphore.release(nil)
    end
  end

  def test_release_raises_error_for_lease_from_different_semaphore
    semaphore1 = CountingSemaphore::LocalSemaphore.new(5)
    semaphore2 = CountingSemaphore::LocalSemaphore.new(5)

    lease = lease1 = semaphore1.acquire(1)
    assert_raises(ArgumentError) do
      semaphore2.release(lease)
    end
    semaphore1.release(lease1)
  end

  def test_try_acquire_succeeds_when_permits_available
    semaphore = CountingSemaphore::LocalSemaphore.new(3)

    lease = semaphore.try_acquire(2)
    refute_nil lease
    assert_instance_of CountingSemaphore::Lease, lease
    assert_equal 1, semaphore.available_permits

    semaphore.release(lease)
  end

  def test_try_acquire_fails_when_permits_not_available
    semaphore = CountingSemaphore::LocalSemaphore.new(2)

    lease = semaphore.acquire(2)
    lease2 = semaphore.try_acquire(1)
    assert_nil lease2
    semaphore.release(lease)
  end

  def test_try_acquire_with_nil_timeout_returns_immediately
    semaphore = CountingSemaphore::LocalSemaphore.new(1)

    lease1 = semaphore.acquire(1)
    start_time = Time.now
    lease2 = semaphore.try_acquire(1, timeout: nil)
    elapsed_time = Time.now - start_time

    assert_nil lease2
    assert elapsed_time < 0.1, "Should return immediately, took #{elapsed_time}s"

    semaphore.release(lease1)
  end

  def test_try_acquire_with_timeout_waits_for_permits
    semaphore = CountingSemaphore::LocalSemaphore.new(1)

    lease = semaphore.acquire(1)
    thread = Thread.new do
      sleep(0.2)
      semaphore.release(lease)
    end

    start_time = Time.now
    lease = semaphore.try_acquire(1, timeout: 0.5)
    elapsed_time = Time.now - start_time

    refute_nil lease
    assert elapsed_time >= 0.2, "Should have waited for release"
    assert elapsed_time < 0.5, "Should not have waited full timeout"

    semaphore.release(lease)
    thread.join
  end

  def test_try_acquire_with_timeout_fails_when_timeout_exceeded
    semaphore = CountingSemaphore::LocalSemaphore.new(1)

    lease1 = semaphore.acquire(1)
    start_time = Time.now

    lease2 = semaphore.try_acquire(1, timeout: 0.2)
    elapsed_time = Time.now - start_time

    assert_nil lease2
    assert elapsed_time >= 0.2, "Should have waited for timeout"

    semaphore.release(lease1)
  end

  def test_try_acquire_defaults_to_one_permit
    semaphore = CountingSemaphore::LocalSemaphore.new(3)

    lease = semaphore.try_acquire
    refute_nil lease
    assert_equal 2, semaphore.available_permits

    semaphore.release(lease)
  end

  def test_try_acquire_raises_error_for_invalid_permits
    semaphore = CountingSemaphore::LocalSemaphore.new(5)

    assert_raises(ArgumentError) do
      semaphore.try_acquire(0)
    end

    assert_raises(ArgumentError) do
      semaphore.try_acquire(-1)
    end
  end

  def test_available_permits_returns_correct_count
    semaphore = CountingSemaphore::LocalSemaphore.new(5)

    assert_equal 5, semaphore.available_permits

    lease1 = semaphore.acquire(2)
    assert_equal 3, semaphore.available_permits

    lease2 = semaphore.acquire(1)
    assert_equal 2, semaphore.available_permits

    semaphore.release(lease2)
    semaphore.release(lease1)
    assert_equal 5, semaphore.available_permits
  end

  def test_available_permits_with_concurrent_operations
    semaphore = CountingSemaphore::LocalSemaphore.new(5)

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
    semaphore = CountingSemaphore::LocalSemaphore.new(5)

    drained_lease = semaphore.drain_permits

    refute_nil drained_lease
    assert_equal 5, drained_lease.permits
    assert_equal 0, semaphore.available_permits

    # Release them back
    semaphore.release(drained_lease)
    assert_equal 5, semaphore.available_permits
  end

  def test_drain_permits_acquires_only_available
    semaphore = CountingSemaphore::LocalSemaphore.new(5)

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
    semaphore = CountingSemaphore::LocalSemaphore.new(3)

    lease = semaphore.acquire(3)
    drained_lease = semaphore.drain_permits

    assert_nil drained_lease
    assert_equal 0, semaphore.available_permits
    semaphore.release(lease)
  end

  def test_acquire_release_maintain_correct_count_under_stress
    semaphore = CountingSemaphore::LocalSemaphore.new(10)
    iterations = 50

    threads = 10.times.map do
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

  def test_concurrent_ruby_api_compatibility_pattern
    semaphore = CountingSemaphore::LocalSemaphore.new(3)
    results = []
    mutex = Mutex.new

    threads = 5.times.map do |i|
      Thread.new do
        if (lease = semaphore.try_acquire(1, timeout: 1.0))
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

    # Only 3 threads should have succeeded (capacity is 3)
    # But all should complete without hanging
    assert results.length > 0, "Expected at least some threads to succeed"
    assert results.length <= 5, "Expected no more threads than total (5)"
    assert_equal 3, semaphore.available_permits
  end
end
