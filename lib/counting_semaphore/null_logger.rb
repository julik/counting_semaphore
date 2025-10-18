# frozen_string_literal: true

module CountingSemaphore
  # A null logger that discards all log messages.
  # Provides the same interface as a real logger but does nothing.
  # Only yields blocks when ENV["RUN_ALL_LOGGER_BLOCKS"] is set to "yes",
  # which is useful in testing. Block form for Logger calls allows you
  # to skip block evaluation if the Logger level is higher than your
  # call, and thus bugs can nest in those Logger blocks. During
  # testing it is helpful to excercise those blocks unconditionally.
  module NullLogger
    # Logs a debug message. Discards the message but may yield the block for testing.
    #
    # @param message [String, nil] Optional message to log (discarded)
    # @yield Optional block that will only be executed if ENV["RUN_ALL_LOGGER_BLOCKS"] == "yes"
    # @return [nil]
    def debug(message = nil, &block)
      yield if block_given? && ENV["RUN_ALL_LOGGER_BLOCKS"] == "yes"
    end

    # Logs an info message. Discards the message but may yield the block for testing.
    #
    # @param message [String, nil] Optional message to log (discarded)
    # @yield Optional block that will only be executed if ENV["RUN_ALL_LOGGER_BLOCKS"] == "yes"
    # @return [nil]
    def info(message = nil, &block)
      yield if block_given? && ENV["RUN_ALL_LOGGER_BLOCKS"] == "yes"
    end

    # Logs a warning message. Discards the message but may yield the block for testing.
    #
    # @param message [String, nil] Optional message to log (discarded)
    # @yield Optional block that will only be executed if ENV["RUN_ALL_LOGGER_BLOCKS"] == "yes"
    # @return [nil]
    def warn(message = nil, &block)
      yield if block_given? && ENV["RUN_ALL_LOGGER_BLOCKS"] == "yes"
    end

    # Logs an error message. Discards the message but may yield the block for testing.
    #
    # @param message [String, nil] Optional message to log (discarded)
    # @yield Optional block that will only be executed if ENV["RUN_ALL_LOGGER_BLOCKS"] == "yes"
    # @return [nil]
    def error(message = nil, &block)
      yield if block_given? && ENV["RUN_ALL_LOGGER_BLOCKS"] == "yes"
    end

    # Logs a fatal message. Discards the message but may yield the block for testing.
    #
    # @param message [String, nil] Optional message to log (discarded)
    # @yield Optional block that will only be executed if ENV["RUN_ALL_LOGGER_BLOCKS"] == "yes"
    # @return [nil]
    def fatal(message = nil, &block)
      yield if block_given? && ENV["RUN_ALL_LOGGER_BLOCKS"] == "yes"
    end

    extend self
  end
end
