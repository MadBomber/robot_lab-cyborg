# frozen_string_literal: true

require "test_helper"
require "stringio"

module RobotLab
  # The duplex human boundary: the network can reach the human (inbound messages
  # are shown on the channel), and the human can reach the network unprompted
  # (always-on listening surfaces initiative). Plus explicit memory attachment.
  class TestDuplex < Minitest::Test
    Terminal = RobotLab::Cyborg::Channel::Terminal
    Scripted = RobotLab::Cyborg::Channel::Scripted

    # --- B2: inbound network traffic is delivered to the human ---------------

    def test_a_peers_reply_is_shown_to_the_human
      bus   = TypedBus::MessageBus.new
      out   = StringIO.new
      human = RobotLab::Cyborg.new(name: "you", bus: bus, channel: Terminal.new(input: StringIO.new, output: out))
      RobotLab::Cyborg.new(name: "peer", bus: bus, channel: Scripted.new(["acknowledged"]))

      message = human.assign(to: :peer, task: "ping")
      wait_until { human.outbox[message.key][:status] == :replied }
      wait_until { out.string.include?("acknowledged") }

      assert_includes out.string, "[peer]"
      assert_includes out.string, "acknowledged"
    end

    # --- B3: always-on listening captures unprompted human input -------------

    def test_listen_surfaces_unprompted_human_input_as_initiative
      seen  = []
      human = RobotLab::Cyborg.new(name: "you", channel: Terminal.new(input: StringIO.new("hello network\n"), output: StringIO.new))
      human.on_human { |m| seen << m.content }
      human.listen

      wait_until { seen.any? }
      assert_equal "hello network", seen.first
    ensure
      human&.interviewer&.close
    end

    def test_without_listen_idle_input_is_not_consumed
      seen  = []
      human = RobotLab::Cyborg.new(name: "you", channel: Terminal.new(input: StringIO.new("ignored\n"), output: StringIO.new))
      human.on_human { |m| seen << m.content }
      # No listen, no outstanding question -> no consumer running.
      sleep 0.15
      assert_empty seen
    end

    # --- A5: explicit memory attach/detach -----------------------------------

    def test_detach_memory_returns_to_standalone_memory
      shared = RobotLab::Memory.new
      human  = RobotLab::Cyborg.new(name: "you", channel: Scripted.new)

      human.attach_memory(shared)
      human.remember(:k, "in-shared")
      assert_equal "in-shared", shared.get(:k)

      human.detach_memory
      human.remember(:k, "in-standalone")
      assert_equal "in-shared", shared.get(:k), "standalone write leaked into shared memory"
      assert_equal "in-standalone", human.recall(:k)
    end
  end
end
