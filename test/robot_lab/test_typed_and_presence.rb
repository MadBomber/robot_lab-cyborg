# frozen_string_literal: true

require "test_helper"

module RobotLab
  # Typed/validated answers (re-ask on bad input) and the presence model.
  class TestTypedAndPresence < Minitest::Test
    Scripted = RobotLab::Cyborg::Channel::Scripted

    # --- typed / validated answers (C) ---------------------------------------

    def test_ask_int_reasks_until_a_number_is_given
      cy = RobotLab::Cyborg.new(name: "you", channel: Scripted.new(%w[banana 42]))
      assert_equal 42, cy.ask_int("How many?", timeout: 1)
    end

    def test_ask_int_gives_up_to_default_after_retries
      cy = RobotLab::Cyborg.new(name: "you", channel: Scripted.new(%w[a b c d e]))
      assert_nil cy.ask_int("How many?", timeout: 1, retries: 1)
    end

    def test_ask_confirm_returns_booleans
      yes = RobotLab::Cyborg.new(name: "y", channel: Scripted.new(["yes"]))
      no  = RobotLab::Cyborg.new(name: "n", channel: Scripted.new(["no"]))
      assert_equal true,  yes.ask_confirm("Ship it?", timeout: 1)
      assert_equal false, no.ask_confirm("Ship it?", timeout: 1)
    end

    def test_validate_coerces_the_answer
      cy = RobotLab::Cyborg.new(name: "you", channel: Scripted.new(["  Ada  "]))
      upper = cy.ask("Name?", timeout: 1, validate: ->(a) { a.strip.upcase })
      assert_equal "ADA", upper
    end

    # --- presence / availability (B8) ----------------------------------------

    def test_presence_transitions
      cy = RobotLab::Cyborg.new(name: "you", channel: Scripted.new)
      assert_equal :online, cy.presence
      assert cy.available?
      cy.offline!
      assert_equal :offline, cy.presence
      refute cy.available?
      cy.online!
      assert cy.available?
    end

    def test_an_offline_human_declines_inbound_tasks_immediately
      bus   = TypedBus::MessageBus.new
      alice = RobotLab::Cyborg.new(name: "alice", bus: bus, channel: Scripted.new)
      bob   = RobotLab::Cyborg.new(name: "bob",   bus: bus, channel: Scripted.new(["should-not-be-used"]))
      bob.offline!

      message = alice.assign(to: :bob, task: "please review")
      wait_until { alice.outbox[message.key][:status] == :replied }

      assert_includes alice.outbox[message.key][:replies].first.content, "unavailable"
      assert_empty bob.channel.asked, "offline human should not have been asked"
    end
  end
end
