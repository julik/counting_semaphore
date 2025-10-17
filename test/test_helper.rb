require "minitest/autorun"
require "timeout"
require "securerandom"

# Set environment variable to run all logger blocks in tests
# Block form for Logger calls allows you
# to skip block evaluation if the Logger level is higher than your
# call, and thus bugs can nest in those Logger blocks. During
# testing it is helpful to excercise those blocks unconditionally.
ENV["RUN_ALL_LOGGER_BLOCKS"] = "yes"
