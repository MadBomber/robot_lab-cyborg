# frozen_string_literal: true

require "test_helper"
require "stringio"

module RobotLab
  # The Interviewer is the *process* that conducts an interaction over a Channel.
  # Asking is always asynchronous: an answer may be the next inbound message,
  # a later one, or never. These tests drive that with deterministic channels.
  class TestInterviewer < Minitest::Test
    Interviewer    = RobotLab::Cyborg::Interviewer
    Terminal       = RobotLab::Cyborg::Channel::Terminal
    Scripted       = RobotLab::Cyborg::Channel::Scripted
    ChannelMessage = RobotLab::Cyborg::ChannelMessage

    # A hand-driven channel: the test pushes inbound messages whenever it likes,
    # so out-of-order answers and unsolicited initiative can be exercised exactly.
    class Probe < RobotLab::Cyborg::Channel
      attr_reader :delivered

      def initialize
        @delivered = []
        @inbox     = Thread::Queue.new
        super
      end

      def deliver(message)
        @delivered << message
        message
      end

      def receive(timeout: nil)
        timeout ? @inbox.pop(timeout: timeout) : @inbox.pop
      end

      def push(content, in_reply_to: nil)
        @inbox.push(ChannelMessage.new(content: content, in_reply_to: in_reply_to))
      end

      def close = @inbox.close
    end

    def teardown
      @interviewer&.close
    end

    # --- async ask -----------------------------------------------------------

    def test_ask_returns_a_pending_question_without_blocking
      @interviewer = Interviewer.new(channel: Probe.new)
      question = @interviewer.ask("Language?")
      assert_kind_of RobotLab::Cyborg::Question, question
      assert_equal "Language?", question.content
    end

    def test_ask_and_wait_returns_the_humans_answer
      @interviewer = Interviewer.new(channel: Scripted.new(["Ruby"]))
      assert_equal "Ruby", @interviewer.ask_and_wait("Language?", timeout: 1)
    end

    # --- correlation ---------------------------------------------------------

    def test_an_answer_resolves_the_question_it_replies_to
      probe = Probe.new
      @interviewer = Interviewer.new(channel: probe)
      question = @interviewer.ask("Deploy?")
      probe.push("yes", in_reply_to: question.id)
      assert_equal "yes", question.answer(timeout: 1)
    end

    def test_answers_without_correlation_match_the_oldest_outstanding_question
      probe = Probe.new
      @interviewer = Interviewer.new(channel: probe)
      first  = @interviewer.ask("first?")
      second = @interviewer.ask("second?")

      probe.push("answer-to-first")   # no in_reply_to -> FIFO -> oldest (first)
      assert_equal "answer-to-first", first.answer(timeout: 1)

      probe.push("answer-to-second")
      assert_equal "answer-to-second", second.answer(timeout: 1)
    end

    def test_the_answer_may_arrive_after_unrelated_input
      probe = Probe.new
      seen  = []
      @interviewer = Interviewer.new(channel: probe).on_initiative { |m| seen << m.content }
      question = @interviewer.ask("Ship it?")

      # The human says two unrelated things first, then finally answers.
      probe.push("btw the CI is green", in_reply_to: -1) # correlated to nothing -> initiative
      probe.push("and the changelog is updated", in_reply_to: -1)
      probe.push("ok ship it", in_reply_to: question.id)

      assert_equal "ok ship it", question.answer(timeout: 1)
      assert_equal ["btw the CI is green", "and the changelog is updated"], seen
    end

    # --- terminal rendering / interpretation ---------------------------------

    def test_terminal_answer_maps_a_number_to_its_choice
      channel = Terminal.new(input: StringIO.new("2\n"), output: StringIO.new)
      @interviewer = Interviewer.new(channel: channel)
      assert_equal "Python", @interviewer.ask_and_wait("Pick:", choices: %w[Ruby Python Go], timeout: 1)
    end

    def test_terminal_applies_the_default_on_an_empty_answer
      channel = Terminal.new(input: StringIO.new("\n"), output: StringIO.new)
      @interviewer = Interviewer.new(channel: channel)
      assert_equal "yes", @interviewer.ask_and_wait("Continue?", default: "yes", timeout: 1)
    end

    def test_terminal_delivers_the_numbered_choices
      out = StringIO.new
      channel = Terminal.new(input: StringIO.new("1\n"), output: out)
      @interviewer = Interviewer.new(channel: channel)
      @interviewer.ask_and_wait("Pick:", choices: %w[Ruby Python], timeout: 1)
      assert_includes out.string, "1. Ruby"
      assert_includes out.string, "2. Python"
    end

    # --- the human may never answer ------------------------------------------

    def test_timeout_falls_back_to_the_default
      @interviewer = Interviewer.new(channel: Scripted.new) # no scripted answers
      assert_equal "abstain", @interviewer.ask_and_wait("Vote?", default: "abstain", timeout: 0.1)
    end

    def test_timeout_without_a_default_returns_nil
      @interviewer = Interviewer.new(channel: Scripted.new)
      assert_nil @interviewer.ask_and_wait("Vote?", timeout: 0.1)
    end

    # --- initiative ----------------------------------------------------------

    def test_uncorrelated_input_is_surfaced_as_initiative
      probe = Probe.new
      seen  = []
      @interviewer = Interviewer.new(channel: probe).on_initiative { |m| seen << m.content }
      # Keep one question outstanding so the consumer is running, then push a
      # message correlated to a question that does not exist.
      @interviewer.ask("pending?")
      probe.push("unprompted status update", in_reply_to: 999)

      wait_until { seen.any? }
      assert_equal ["unprompted status update"], seen
    end
  end
end
