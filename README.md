# counting_semaphore

A counting semaphore implementation for Ruby with local and distributed (Redis) variants.

> [!TIP]
> This gem was created for [Cora,](https://cora.computer/) 
> your personal e-mail assistant. 
> Send them some love for allowing me to share it.

## What is it for?

When you have a _metered and limited_ resource that only supports a certain number of simultaneous operations you need a [semaphore](https://en.wikipedia.org/wiki/Semaphore_(programming)) primitive. In Ruby, most semaphores usually controls access "one whole resource":

```ruby
sem = Semaphore.new
sem.with_lease do
  # Critical section where you hold access to the resource
end
```

This is well covered - for example - by POSIX semaphores if you are within one machine, and is known as a _binary semaphore_ (it is either "open" or "closed"). There are also _counting_ semaphores where you permit N of leases to be taken, which is available in the venerable [redis-semaphore](https://github.com/dv/redis-semaphore) gem.

The problem comes if you need to hold access to a certain _amount_ of a resource. For example, you know that you are doing 5 expensive operations in bulk, and you know that your entire application can only be doing 20 in total - governed by the API access limits. For that, you need a [counting semaphore](https://ruby-concurrency.github.io/concurrent-ruby/master/Concurrent/Semaphore.html#acquire-instance_method) - such a semaphore is provided by [concurrent-ruby](https://ruby-concurrency.github.io/concurrent-ruby/master/Concurrent/Semaphore.html#acquire-instance_method) for example. It allows you to acquire a certain number of _permits_ and then release them.

This library provides both a simple `LocalSemaphore` which can be used across threads or fibers, and a Redis-based `RedisSemaphore` for coordination across processes and machines. Both implement a Lease-based API compatible with concurrent-ruby's Semaphore.

## Usage

### Basic Usage with `with_lease`

The recommended way to use the semaphore is with the `with_lease` method, which provides automatic cleanup:

```ruby
require 'counting_semaphore'

# Create a local semaphore with capacity of 10
semaphore = CountingSemaphore::LocalSemaphore.new(10)

# Acquire 3 permits and automatically release on block exit
semaphore.with_lease(3, timeout_seconds: 10) do
  puts "Holding 3 permits"
  # Do your work here - permits are automatically released when the block exits
end
```

The block receives the lease object, which you can inspect:

```ruby
semaphore.with_lease(3) do |lease|
  puts "Holding #{lease.permits} permits (ID: #{lease.id})"
  # Automatic cleanup on block exit
end
```

### Distributed Semaphore with Redis

The Redis semaphore works identically but coordinates across processes and machines:

```ruby
require 'redis'

redis = Redis.new
semaphore = CountingSemaphore::RedisSemaphore.new(
  10,                    # capacity
  "api_ratelimit",       # namespace (unique identifier)
  redis: redis,
  lease_ttl_seconds: 60  # lease expires after 60 seconds
)

# Use it the same way - works across multiple processes
semaphore.with_lease(3) do
  puts "Doing distributed work with 3 permits"
  # Permits automatically released when done
end
```

### Checking Availability

You can query the current state of the semaphore:

```ruby
puts "Available permits: #{semaphore.available_permits}"
puts "Capacity: #{semaphore.capacity}"
puts "Currently in use: #{semaphore.currently_leased}"
```

### Advanced: Manual Lease Control

For more control, you can manually acquire and release leases. This is useful when you can't use a block structure:

```ruby
# Acquire permits (returns a Lease object)
lease = semaphore.acquire(2)

begin
  # Do some work
  puts "Working with 2 permits..."
ensure
  # Always release the lease
  semaphore.release(lease)
end
```

#### Try Acquire with Timeout

```ruby
# Try to acquire immediately (returns nil if not available)
lease = semaphore.try_acquire(1)
if lease
  begin
    puts "Got the permit!"
  ensure
    semaphore.release(lease)
  end
else
  puts "Could not acquire permit"
end

# Try to acquire with timeout
lease = semaphore.try_acquire(2, 5.0)  # Wait up to 5 seconds
if lease
  begin
    # Work with the permits
  ensure
    semaphore.release(lease)
  end
end
```

#### Drain All Available Permits

```ruby
# Acquire all currently available permits
drained_lease = semaphore.drain_permits

if drained_lease
  begin
    puts "Drained #{drained_lease.permits} permits for exclusive access"
    # Do exclusive work
  ensure
    semaphore.release(drained_lease)
  end
end
```

### Key Benefits

1. **Automatic Cleanup**: `with_lease` ensures permits are always released
2. **Type Safety**: Lease objects ensure you can only release what you've acquired
3. **Cross-Semaphore Protection**: Can't accidentally release a lease to the wrong semaphore
4. **Distributed Coordination**: Redis semaphore works seamlessly across processes and machines
5. **Lease Expiration**: Redis leases automatically expire to prevent deadlocks

## Design Philosophy

This library aims for compatibility with [`Concurrent::Semaphore`](https://ruby-concurrency.github.io/concurrent-ruby/1.1.5/Concurrent/Semaphore.html) from the concurrent-ruby gem, but with a key difference to support both local and distributed implementations.

### How It Works

The core difference from `Concurrent::Semaphore` is that **`acquire` returns a lease object** that must be passed to `release`, rather than using numeric permit counts for both operations:

```ruby
# concurrent-ruby style
semaphore.acquire(2)
# ... work ...
semaphore.release(2)  # Must remember the count!

# counting_semaphore style
lease = semaphore.acquire(2)
# ... work ...
semaphore.release(lease)  # Lease knows its own count
```

#### Why Not 100% API Parity?

The `Concurrent::Semaphore` API where `acquire(n)` and `release(n)` use arbitrary counts works well for in-memory semaphores, but creates challenges for distributed Redis-based implementations:

1. **Individual leases need TTLs**: In Redis, each lease must have an expiration to prevent deadlocks from crashed processes
2. **Lease tracking is essential**: Distributed systems need unique identifiers for each acquired lease
3. **Cross-process coordination**: Releasing "2 permits" doesn't map cleanly to "which 2 leases?" across processes
4. **Ownership semantics**: The lease object makes it explicit what you acquired and what you're releasing

#### The Lease Object

A lease is a simple struct that contains:
- `semaphore` - reference to the semaphore it came from
- `id` - unique identifier (local counter for LocalSemaphore, Redis key for RedisSemaphore)
- `permits` - number of permits held

This design:
- **Prevents bugs**: Can't accidentally release the wrong amount or to the wrong semaphore
- **Works for both implementations**: LocalSemaphore and RedisSemaphore use the same API
- **Follows familiar patterns**: Similar to file handles, database connections, and other resource management
- **Maintains compatibility**: The `with_lease` block form works identically to concurrent-ruby's usage

#### Query Methods

The library provides the same query methods as `Concurrent::Semaphore`:

- `available_permits` - returns the number of permits currently available
- `capacity` - returns the total capacity of the semaphore
- `currently_leased` - returns the number of permits currently in use

Additionally, `drain_permits` returns a lease object (or nil) instead of an integer, maintaining consistency with the lease-based design.

## Installation

Add this line to your application's Gemfile:

```ruby
gem "counting_semaphore"
```

And then execute:

    $ bundle install

Or install it yourself as:

    $ gem install counting_semaphore

There are no dependencies (but you need the `redis` gem for development - or you can feed a compatible object instead).

## Development

Do a fresh checkout and run `bundle install`. Then run tests and linting using `bundle exec rake`.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/julik/counting_semaphore.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
