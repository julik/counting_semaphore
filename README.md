# CountingSemaphore

A counting semaphore implementation for Ruby with local and distributed (Redis) variants.

## Installation

Add this line to your application's Gemfile:

```ruby
gem "counting_semaphore"
```

And then execute:

    $ bundle install

Or install it yourself as:

    $ gem install counting_semaphore

## Usage

### Local Semaphore

For in-process coordination:

```ruby
require "counting_semaphore"

# Create a semaphore that allows up to 5 concurrent operations
semaphore = CountingSemaphore::LocalSemaphore.new(5)

# Use the semaphore to control access to a resource
semaphore.with_lease(2) do
  # This block can only run when 2 tokens are available
  # Do your work here
  puts "Doing work that requires 2 tokens"
end
```

### Redis Semaphore (Redis-based)

For distributed coordination across multiple processes:

```ruby
require "counting_semaphore"
require "redis"  # Redis is required for RedisSemaphore

# Create a Redis semaphore using Redis
 # You can also pass your ConnectionPool instance.
redis = Redis.new
semaphore = CountingSemaphore::RedisSemaphore.new(10, "my_namespace", redis: redis)

# Use the semaphore across multiple processes
semaphore.with_lease(3) do
  # This block can only run when 3 tokens are available
  # Works across multiple processes/machines
  puts "Doing distributed work"
end
```

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake test` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/yourusername/counting_semaphore.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
