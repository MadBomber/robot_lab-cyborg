# frozen_string_literal: true

require "test_helper"

module RobotLab
  class TestCyborg < Minitest::Test
    Scripted = RobotLab::Cyborg::Channel::Scripted

    def test_that_it_has_a_version_number
      refute_nil ::RobotLab::Cyborg::VERSION
    end

    def test_extension_registers_with_robot_lab
      assert RobotLab.extension_loaded?(:cyborg)
      assert_equal RobotLab::Cyborg, RobotLab.extension(:cyborg)
    end

    def test_name_is_a_string
      cyborg = RobotLab::Cyborg.new(name: :dewayne, channel: Scripted.new)
      assert_equal "dewayne", cyborg.name
    end

    def test_defaults_to_a_terminal_channel
      cyborg = RobotLab::Cyborg.new(name: "dewayne")
      assert_instance_of RobotLab::Cyborg::Channel::Terminal, cyborg.channel
    end

    def test_ask_delegates_to_the_interviewer
      cyborg = RobotLab::Cyborg.new(name: "dewayne", channel: Scripted.new(["blue"]))
      assert_equal "blue", cyborg.ask("Favorite color?")
    end

    def test_run_returns_a_robot_result_carrying_the_human_answer
      cyborg = RobotLab::Cyborg.new(name: "dewayne", channel: Scripted.new(["approved"]))
      result = cyborg.run("Approve this?")

      assert_instance_of RobotLab::RobotResult, result
      assert_equal "approved", result.reply
      assert_equal "dewayne", result.robot_name
    end

    def test_to_h_describes_a_cyborg
      cyborg = RobotLab::Cyborg.new(name: "dewayne", channel: Scripted.new)
      hash = cyborg.to_h

      assert_equal "dewayne", hash[:name]
      assert_equal :cyborg, hash[:kind]
    end

    def test_remember_and_recall_use_its_own_memory_when_standalone
      cyborg = RobotLab::Cyborg.new(name: "dewayne", channel: Scripted.new)
      cyborg.remember(:decision, "ship it")
      assert_equal "ship it", cyborg.recall(:decision)
    end
  end
end
