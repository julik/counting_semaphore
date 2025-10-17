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
    result = semaphore.with_lease(1, timeout_seconds: 5) do
      "success"
    end

    assert_equal "success", result
  end

  def test_with_lease_raises_timeout_error_when_timeout_is_exceeded
    semaphore = CountingSemaphore::LocalSemaphore.new(1)

    # Fill the semaphore
    semaphore.with_lease(1) do
      # Try to acquire another token with a very short timeout
      assert_raises(Timeout::Error) do
        semaphore.with_lease(1, timeout_seconds: 0.1) do
          "should not reach here"
        end
      end
    end
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
end
