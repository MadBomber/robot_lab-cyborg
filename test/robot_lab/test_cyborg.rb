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

    # --- spawn: a human has no model/provider for a spawned robot to inherit ---

    def test_inherited_llm_settings_is_empty
      cyborg = RobotLab::Cyborg.new(name: "dewayne", channel: Scripted.new)
      assert_empty cyborg.inherited_llm_settings
    end

    def test_spawn_builds_a_robot_on_the_shared_bus_with_the_callers_llm_settings
      cyborg = RobotLab::Cyborg.new(name: "dewayne", channel: Scripted.new)
      robot  = cyborg.spawn(name: "helper", system_prompt: "Be brief.", model: "gpt-4o-mini", provider: "openai")

      assert_instance_of RobotLab::Robot, robot
      assert_equal "helper", robot.name
      assert_equal "gpt-4o-mini", robot.model
      assert_equal "openai", robot.provider
      refute_nil cyborg.bus
      assert_same cyborg.bus, robot.bus
    end

    def test_spawn_without_llm_settings_falls_back_to_the_configured_defaults
      bus    = TypedBus::MessageBus.new
      cyborg = RobotLab::Cyborg.new(name: "dewayne", bus: bus, channel: Scripted.new)
      robot  = cyborg.spawn(name: "helper", system_prompt: "Be brief.")

      assert_instance_of RobotLab::Robot, robot
      assert_same bus, robot.bus
    end

    # --- remember attributes the write to this peer ----------------------------

    def test_remember_attributes_the_write_to_this_peer
      memory  = RobotLab::Memory.new
      writers = []
      memory.subscribe(:decision) { |change| writers << change.writer }
      cyborg = RobotLab::Cyborg.new(name: "dewayne", channel: Scripted.new, memory: memory)

      assert_equal "ship it", cyborg.remember(:decision, "ship it")

      wait_until { writers.any? }
      assert_equal ["dewayne"], writers
    end

    def test_remember_restores_the_previous_writer
      memory = RobotLab::Memory.new
      memory.current_writer = "someone_else"
      cyborg = RobotLab::Cyborg.new(name: "dewayne", channel: Scripted.new, memory: memory)

      cyborg.remember(:decision, "ship it")

      assert_equal "someone_else", memory.current_writer
    end

    def test_remember_attributes_writes_to_an_attached_shared_memory
      shared  = RobotLab::Memory.new
      writers = []
      shared.subscribe(:decision) { |change| writers << change.writer }
      cyborg = RobotLab::Cyborg.new(name: "dewayne", channel: Scripted.new).attach_memory(shared)

      cyborg.remember(:decision, "ship it")

      wait_until { writers.any? }
      assert_equal ["dewayne"], writers
      assert_nil shared.current_writer
    end
  end
end
