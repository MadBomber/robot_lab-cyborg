# frozen_string_literal: true

require "test_helper"
require "stringio"

module RobotLab
  # A Channel is a dumb bidirectional pipe: it delivers messages out to the
  # human and surfaces messages the human sends in. It knows nothing about
  # questions or answers — that is the Interviewer's job.
  class TestChannel < Minitest::Test
    Channel        = RobotLab::Cyborg::Channel
    Terminal       = RobotLab::Cyborg::Channel::Terminal
    Scripted       = RobotLab::Cyborg::Channel::Scripted
    ChannelMessage = RobotLab::Cyborg::ChannelMessage

    # --- base ----------------------------------------------------------------

    def test_base_deliver_is_abstract
      assert_raises(NotImplementedError) { Channel.new.deliver(ChannelMessage.new(content: "hi")) }
    end

    def test_base_receive_is_abstract
      assert_raises(NotImplementedError) { Channel.new.receive }
    end

    # --- terminal ------------------------------------------------------------

    def test_terminal_deliver_writes_the_labeled_message
      out = StringIO.new
      Terminal.new(output: out, name: "dewayne").deliver(ChannelMessage.new(content: "Ready?"))
      assert_includes out.string, "[dewayne] Ready?"
    end

    def test_terminal_receive_reads_a_line_as_an_inbound_message
      channel = Terminal.new(input: StringIO.new("Ruby\n"), output: StringIO.new)
      message = channel.receive
      assert_equal "Ruby", message.content
    end

    def test_terminal_receive_returns_nil_at_eof
      channel = Terminal.new(input: StringIO.new(""), output: StringIO.new)
      assert_nil channel.receive
    end

    def test_terminal_inbound_carries_no_correlation
      channel = Terminal.new(input: StringIO.new("hi\n"), output: StringIO.new)
      assert_nil channel.receive.in_reply_to
    end

    # --- scripted ------------------------------------------------------------

    def test_scripted_pairs_each_delivery_with_the_next_answer
      channel = Scripted.new(%w[one two])
      channel.deliver(ChannelMessage.new(id: 1, content: "a?"))
      assert_equal "one", channel.receive.content
      channel.deliver(ChannelMessage.new(id: 2, content: "b?"))
      assert_equal "two", channel.receive.content
    end

    def test_scripted_stamps_the_answer_with_the_question_id
      channel = Scripted.new(["yes"])
      channel.deliver(ChannelMessage.new(id: 42, content: "go?"))
      assert_equal 42, channel.receive.in_reply_to
    end

    def test_scripted_records_every_question_delivered
      channel = Scripted.new(%w[one])
      channel.deliver(ChannelMessage.new(id: 1, content: "first?"))
      channel.deliver(ChannelMessage.new(id: 2, content: "second?"))
      assert_equal ["first?", "second?"], channel.asked
    end

    def test_scripted_yields_no_answer_when_the_script_is_exhausted
      channel = Scripted.new
      channel.deliver(ChannelMessage.new(id: 1, content: "q?"))
      assert_nil channel.receive(timeout: 0.05)
    end
  end
end
