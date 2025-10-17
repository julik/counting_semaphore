module CountingSemaphore
  # A null logger that discards all log messages
  # Provides the same interface as a real logger but does nothing
  # Only yields blocks when ENV["RUN_ALL_LOGGER_BLOCKS"] is set to "yes"
  module NullLogger
    def self.debug(message = nil, &block)
      yield if block_given? && ENV["RUN_ALL_LOGGER_BLOCKS"] == "yes"
    end

    def self.info(message = nil, &block)
      yield if block_given? && ENV["RUN_ALL_LOGGER_BLOCKS"] == "yes"
    end

    def self.warn(message = nil, &block)
      yield if block_given? && ENV["RUN_ALL_LOGGER_BLOCKS"] == "yes"
    end

    def self.error(message = nil, &block)
      yield if block_given? && ENV["RUN_ALL_LOGGER_BLOCKS"] == "yes"
    end

    def self.fatal(message = nil, &block)
      yield if block_given? && ENV["RUN_ALL_LOGGER_BLOCKS"] == "yes"
    end
  end
end
