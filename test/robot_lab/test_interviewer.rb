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

    # --- robustness: a throwing handler must not wedge the interviewer (A1) ----

    def test_a_throwing_initiative_handler_does_not_kill_the_consumer
      probe = Probe.new
      @interviewer = Interviewer.new(channel: probe).on_initiative { |_m| raise "handler boom" }
      question = @interviewer.ask("still alive?")

      probe.push("noise", in_reply_to: 999) # -> initiative -> raises inside consumer
      probe.push("the real answer", in_reply_to: question.id)

      assert_equal "the real answer", question.answer(timeout: 2)
      assert_kind_of RuntimeError, @interviewer.last_error
    end

    def test_a_new_ask_still_works_after_a_handler_error
      probe = Probe.new
      @interviewer = Interviewer.new(channel: probe).on_initiative { |_m| raise "boom" }
      q1 = @interviewer.ask("one")
      probe.push("boom", in_reply_to: 999)
      probe.push("a1", in_reply_to: q1.id)
      assert_equal "a1", q1.answer(timeout: 2)

      q2 = @interviewer.ask("two")
      probe.push("a2", in_reply_to: q2.id)
      assert_equal "a2", q2.answer(timeout: 2), "interviewer wedged after a handler error"
    end

    # --- serialization on a non-correlating channel (B6, fixes A3) ------------

    def test_only_one_question_is_on_the_wire_at_a_time
      probe = Probe.new # correlates? == false
      @interviewer = Interviewer.new(channel: probe)
      q1 = @interviewer.ask("first")
      q2 = @interviewer.ask("second")

      assert_equal ["first"], probe.delivered.map(&:content), "second question delivered too early"

      probe.push("answer one") # no correlation -> resolves the active question
      assert_equal "answer one", q1.answer(timeout: 2)

      wait_until { probe.delivered.size == 2 }
      assert_equal "second", probe.delivered.last.content
      probe.push("answer two")
      assert_equal "answer two", q2.answer(timeout: 2)
    end

    def test_a_correlating_channel_allows_concurrent_questions
      @interviewer = Interviewer.new(channel: Scripted.new(%w[a b]))
      # Scripted correlates, so both questions are delivered immediately.
      one = @interviewer.ask("q1")
      two = @interviewer.ask("q2")
      assert_equal "a", one.answer(timeout: 2)
      assert_equal "b", two.answer(timeout: 2)
    end

    # --- timeout on an interruptible terminal (A4) ---------------------------

    def test_timeout_returns_default_on_a_silent_terminal
      channel = Terminal.new(input: StringIO.new(""), output: StringIO.new)
      @interviewer = Interviewer.new(channel: channel)
      assert_equal "abstain", @interviewer.ask_and_wait("Vote?", default: "abstain", timeout: 0.2)
    end
  end
end
