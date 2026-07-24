# frozen_string_literal: true

require "test_helper"
require "stringio"

module RobotLab
  # A Conversation routes the human's messages onto the bus by @mention — the
  # addressing/fan-out/broadcast that used to live in example code.
  class TestConversation < Minitest::Test
    Conversation = RobotLab::Cyborg::Conversation
    Scripted     = RobotLab::Cyborg::Channel::Scripted
    Terminal     = RobotLab::Cyborg::Channel::Terminal

    def setup
      @bus = TypedBus::MessageBus.new
      @you = RobotLab::Cyborg.new(name: "you", bus: @bus, channel: Scripted.new)
      # Two auto-replying peers so we can observe what got tasked.
      @analyst = RobotLab::Cyborg.new(name: "analyst", bus: @bus, channel: Scripted.new(%w[a a a]))
      @scribe  = RobotLab::Cyborg.new(name: "scribe",  bus: @bus, channel: Scripted.new(%w[s s s]))
      @chat = Conversation.new(cyborg: @you, peers: %w[analyst scribe])
    end

    def test_single_mention_routes_to_that_peer
      recipients = @chat.route("hey @analyst what's the error rate?")
      assert_equal ["analyst"], recipients
    end

    def test_multiple_mentions_anywhere_fan_out
      recipients = @chat.route("@scribe note that @analyst is on call")
      assert_equal %w[scribe analyst], recipients
    end

    def test_no_mention_broadcasts_to_all_known_peers
      recipients = @chat.route("standup in five, everyone")
      assert_equal %w[analyst scribe], recipients
    end

    def test_duplicate_mentions_are_deduped
      assert_equal ["scribe"], @chat.route("@scribe and @scribe again")
    end

    def test_unknown_only_mention_sends_nothing
      assert_empty @chat.route("@nobody are you there?")
    end

    def test_empty_line_sends_nothing
      assert_empty @chat.route("   ")
    end

    def test_the_whole_message_including_mentions_is_delivered
      @chat.route("ping @analyst")
      wait_until { @analyst.channel.asked.any? }
      assert_includes @analyst.channel.asked.first, "ping @analyst"
    end

    def test_add_peer_extends_the_roster
      @chat.add_peer("ops")
      assert_includes @chat.peers, "ops"
    end

    def test_unknown_mention_is_reported_to_the_human
      out = StringIO.new
      you = RobotLab::Cyborg.new(name: "you_u", bus: @bus, channel: Terminal.new(input: StringIO.new, output: out))
      Conversation.new(cyborg: you, peers: %w[analyst]).route("@ghost hi")
      assert_includes out.string, "No such peer: @ghost"
    end

    def test_start_routes_listened_input_over_the_bus
      out = StringIO.new
      you = RobotLab::Cyborg.new(name: "you_l", bus: @bus,
                                 channel: Terminal.new(input: StringIO.new("@analyst status?\n"), output: out))
      Conversation.new(cyborg: you, peers: %w[analyst]).start
      wait_until { @analyst.channel.asked.any? }
      assert_includes @analyst.channel.asked.last, "status?"
    ensure
      you&.interviewer&.close
    end

    def test_cyborg_converse_returns_a_started_conversation
      you = RobotLab::Cyborg.new(name: "you_c", bus: @bus, channel: Scripted.new)
      chat = you.converse(peers: %w[analyst scribe])
      assert_instance_of Conversation, chat
      assert_equal %w[analyst scribe], chat.peers
    ensure
      you&.unlisten
    end
  end
end
