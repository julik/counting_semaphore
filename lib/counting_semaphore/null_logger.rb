module CountingSemaphore
  # A null logger that discards all log messages
  # Provides the same interface as a real logger but does nothing
  # Only yields blocks when ENV["RUN_ALL_LOGGER_BLOCKS"] is set to "yes",
  # which is useful in testing. Block form for Logger calls allows you
  # to skip block evaluation if the Logger level is higher than your
  # call, and thus bugs can nest in those Logger blocks. During
  # testing it is helpful to excercise those blocks unconditionally.
  module NullLogger
    def debug(message = nil, &block)
      yield if block_given? && ENV["RUN_ALL_LOGGER_BLOCKS"] == "yes"
    end

    def info(message = nil, &block)
      yield if block_given? && ENV["RUN_ALL_LOGGER_BLOCKS"] == "yes"
    end

    def warn(message = nil, &block)
      yield if block_given? && ENV["RUN_ALL_LOGGER_BLOCKS"] == "yes"
    end

    def error(message = nil, &block)
      yield if block_given? && ENV["RUN_ALL_LOGGER_BLOCKS"] == "yes"
    end

    def fatal(message = nil, &block)
      yield if block_given? && ENV["RUN_ALL_LOGGER_BLOCKS"] == "yes"
    end

    extend self
  end
end
