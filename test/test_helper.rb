# frozen_string_literal: true

require "simplecov"
SimpleCov.start do
  skip "/test/"
  skip "/vendor/"

  group "Cyborg", "lib/robot_lab/cyborg"

  enable_coverage :branch
end

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "robot_lab"
require "robot_lab/cyborg"

require "minitest/autorun"

module Minitest
  class Test
    # Poll a condition until it holds, for asserting on asynchronous bus
    # delivery without hard-coding sleeps.
    def wait_until(timeout: 2, interval: 0.01)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        return true if yield
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          flunk "wait_until timed out after #{timeout}s"
        end
        sleep interval
      end
    end
  end
end
