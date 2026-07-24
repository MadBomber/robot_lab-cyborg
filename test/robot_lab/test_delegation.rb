# frozen_string_literal: true

require "test_helper"

module RobotLab
  # A Cyborg can both receive delegated work (its `run` is the injection point)
  # and issue delegated work to other members, synchronously or asynchronously.
  class TestDelegation < Minitest::Test
    Scripted = RobotLab::Cyborg::Channel::Scripted

    def test_sync_delegation_returns_a_result_stamped_with_the_delegator
      alice = RobotLab::Cyborg.new(name: "alice", channel: Scripted.new)
      bob   = RobotLab::Cyborg.new(name: "bob",   channel: Scripted.new(["42"]))

      result = alice.delegate(to: bob, task: "What is the answer?")

      assert_equal "42", result.reply
      assert_equal "alice", result.delegated_by
      assert_equal "bob", result.robot_name
    end

    def test_async_delegation_returns_a_future_that_resolves
      alice = RobotLab::Cyborg.new(name: "alice", channel: Scripted.new)
      bob   = RobotLab::Cyborg.new(name: "bob",   channel: Scripted.new(["async-42"]))

      future = alice.delegate(to: bob, task: "again", async: true)

      assert_instance_of RobotLab::DelegationFuture, future
      assert_equal "async-42", future.value.reply
      assert_equal "alice", future.value.delegated_by
    end

    def test_the_human_behind_the_delegatee_sees_the_task
      alice = RobotLab::Cyborg.new(name: "alice", channel: Scripted.new)
      bob   = RobotLab::Cyborg.new(name: "bob",   channel: Scripted.new(["ok"]))

      alice.delegate(to: bob, task: "Please review PR #7")

      assert_includes bob.channel.asked.first, "Please review PR #7"
    end
  end
end
