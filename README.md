# counting_semaphore

A counting semaphore implementation for Ruby with local and distributed (Redis) variants.

> [!TIP]
> This gem was created for [Cora,](https://cora.computer/) 
> your personal e-mail assistant. 
> Send them some love for allowing me to share it.

## What is it for?

When you have a metered and limited resource that only supports a certain number of simultaneous operations you need a [semaphore](https://en.wikipedia.org/wiki/Semaphore_(programming)) primitive. In Ruby, a semaphore usually controls access to "one whole resource":

```ruby
sem = Semaphore.new
sem.with_lease do
  # Critical section where you hold access to the resource
end
```

This is well covered - for example - by POSIX semaphores if you are within one machine, or by the venerable [redis-semaphore](https://github.com/dv/redis-semaphore)

The problem comes if you need to hold access to a certain _amount_ of a resource. For example, you know that you are doing 5 expensive operations in bulk, and you know that your entire application can only be doing 20 in total - governed by the API access limits. For that, you need a [counting semaphore](https://ruby-concurrency.github.io/concurrent-ruby/master/Concurrent/Semaphore.html#acquire-instance_method) - such a semaphore is provided by [concurrent-ruby](https://ruby-concurrency.github.io/concurrent-ruby/master/Concurrent/Semaphore.html#acquire-instance_method) for example. It allows you to acquire a certain number of _permits_ and then release them.

This library does the same and also has a simple `LocalSemaphore` which can be used across threads or fibers. This allows for coordination if you are only running one process/Ractor. It is thread-safe and fairly simple in operation:

```ruby
require "counting_semaphore"

# Create a semaphore that allows up to 10 concurrent operations
semaphore = CountingSemaphore::LocalSemaphore.new(10)

# Do an operation that occupies 2 slots
semaphore.with_lease(2) do
  # This block can only run when 2 tokens are available
  # Do your work here
  puts "Doing work that requires 2 tokens"
end
```

However, we also include a Redis based _shared counting semaphore_ which you can use for resource access control across processes and across machines - provided they have access to a shared Redis server. The semaphore is identified by a _namespace_ - think of it as the `id` of the semaphore. Leases are obtained and released using Redis blocking operations and Lua scripts (for atomicity):

```ruby
require "counting_semaphore"
require "redis"  # Redis is required for RedisSemaphore

# Create a Redis semaphore using Redis
# You can also pass your ConnectionPool instance.
redis = Redis.new
semaphore = CountingSemaphore::RedisSemaphore.new(10, "api_ratelimit", redis:)

# and then use it the same as the LocalSemaphore
semaphore.with_lease(3) do
  # This block can only run when 3 tokens are available
  # Works across multiple processes/machines
  puts "Doing distributed work"
end
```

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
