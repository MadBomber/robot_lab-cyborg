# frozen_string_literal: true

require "test_helper"

module RobotLab
  # Cyborgs speak on the same TypedBus channels as robots. These tests exercise
  # the peer-to-peer path: one peer issues a task by name, the receiving peer's
  # human answers, and the reply is correlated back into the issuer's outbox.
  class TestBus < Minitest::Test
    Scripted = RobotLab::Cyborg::Channel::Scripted

    def test_task_issue_reply_round_trip
      bus   = TypedBus::MessageBus.new
      alice = RobotLab::Cyborg.new(name: "alice", bus: bus, channel: Scripted.new)
      bob   = RobotLab::Cyborg.new(name: "bob",   bus: bus, channel: Scripted.new(["yes, go"]))

      message = alice.assign(to: :bob, task: "Approve deploy?")

      wait_until { alice.outbox[message.key][:status] == :replied }

      entry = alice.outbox[message.key]
      assert_equal :replied, entry[:status]
      assert_equal "yes, go", entry[:replies].first.content
      assert_equal 1, bob.inbox.size
      assert_includes bob.channel.asked.first, "Approve deploy?"
    end

    def test_auto_reply_can_be_disabled
      bus   = TypedBus::MessageBus.new
      alice = RobotLab::Cyborg.new(name: "alice", bus: bus, channel: Scripted.new)
      bob   = RobotLab::Cyborg.new(name: "bob",   bus: bus, channel: Scripted.new(["noted"]),
                                   auto_reply: false)

      message = alice.assign(to: :bob, task: "FYI: window at 15:00")

      # The inbound task is answered off the poller thread now, so wait for the
      # human to have been asked rather than merely for delivery.
      wait_until { bob.channel.asked.any? }
      # bob's human saw it, but no reply was sent back to alice
      assert_includes bob.channel.asked.first, "window at 15:00"
      sleep 0.05
      assert_equal :sent, alice.outbox[message.key][:status]
    end

    def test_on_task_callback_fires_with_message_and_answer
      bus   = TypedBus::MessageBus.new
      alice = RobotLab::Cyborg.new(name: "alice", bus: bus, channel: Scripted.new)
      bob   = RobotLab::Cyborg.new(name: "bob",   bus: bus, channel: Scripted.new(["done"]))

      seen = []
      bob.on_task { |msg, answer| seen << [msg.from, answer] }

      alice.assign(to: :bob, task: "Do the thing")

      wait_until { seen.any? }
      assert_equal %w[alice done], seen.first
    end

    def test_assign_without_a_bus_raises
      lonely = RobotLab::Cyborg.new(name: "lonely", channel: Scripted.new)
      assert_raises(RobotLab::BusError) { lonely.assign(to: :nobody, task: "hi") }
    end
  end
end
