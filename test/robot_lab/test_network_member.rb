# frozen_string_literal: true

require "test_helper"

module RobotLab
  # A Cyborg must behave as a genuine, peer-level network member: it takes a
  # pipeline step, its output flows downstream, and it reads/writes the same
  # shared memory as every other member.
  class TestNetworkMember < Minitest::Test
    Scripted = RobotLab::Cyborg::Channel::Scripted

    def test_cyborg_is_a_pipeline_step_and_its_answer_is_the_result
      approver = RobotLab::Cyborg.new(name: "approver", channel: Scripted.new(["approved"]))

      network = RobotLab.create_network(name: "release") do
        task :approver, approver, depends_on: :none
      end

      result = network.run(message: "Approve the release?")

      # Keyed by the member's name, exactly as a robot's result would be.
      assert_equal "approved", result.context[:approver].reply
      assert_equal "approved", result.value.reply
    end

    def test_the_human_is_shown_the_incoming_task
      approver = RobotLab::Cyborg.new(name: "approver", channel: Scripted.new(["ok"]))

      network = RobotLab.create_network(name: "release") do
        task :approve, approver, depends_on: :none
      end
      network.run(message: "Please approve the release")

      assert_includes approver.channel.asked.first, "Please approve the release"
    end

    def test_tasking_flows_from_one_member_to_the_next
      first  = RobotLab::Cyborg.new(name: "first",  channel: Scripted.new(["handoff-payload"]))
      second = RobotLab::Cyborg.new(name: "second", channel: Scripted.new(["done"]))

      network = RobotLab.create_network(name: "chain") do
        task :first,  first,  depends_on: :none
        task :second, second, depends_on: [:first]
      end
      result = network.run(message: "start")

      # The second member received the first member's output as its own task.
      assert_includes second.channel.asked.join(" "), "handoff-payload"
      assert_equal "done", result.context[:second].reply
    end

    def test_peers_share_network_memory
      mem   = RobotLab::Memory.new
      alice = RobotLab::Cyborg.new(name: "alice", channel: Scripted.new(["ok"]))
      bob   = RobotLab::Cyborg.new(name: "bob",   channel: Scripted.new(["ok"]))

      # Both run against the same shared (network) memory.
      alice.run("go", network_memory: mem)
      bob.run("go", network_memory: mem)

      alice.remember(:decision, "ship it")
      assert_equal "ship it", bob.recall(:decision)
    end
  end
end
