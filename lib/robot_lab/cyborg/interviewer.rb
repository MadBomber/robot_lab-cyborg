# frozen_string_literal: true

module RobotLab
  class Cyborg
    # An Interviewer is the *process* of conducting a human interaction over a
    # {Channel} (the *means*). The channel moves opaque messages; the Interviewer
    # gives them meaning — it tracks which questions are outstanding, decides
    # which inbound message answers which question, and surfaces the rest as
    # unsolicited human initiative.
    #
    # Asking is *always asynchronous*, whatever the channel. A human's answer may
    # be the very next message, may arrive several messages later (after they say
    # other things first), or may never come at all. So {#ask} does not block for
    # an answer — it delivers the question and returns a {Question} you can wait
    # on, with a timeout, whenever you are ready. A background consumer drains the
    # channel and resolves questions as their answers arrive.
    #
    # Correlation: when an inbound message carries an +in_reply_to+ (a rich
    # transport like Slack threads its replies) it resolves exactly that
    # question; otherwise the oldest outstanding question is assumed (FIFO), which
    # is the best a bare terminal can do.
    class Interviewer
      # How often the background consumer wakes to poll the channel.
      POLL_INTERVAL = 0.05

      # @param channel [Channel] the injected means of reaching the human
      # @param default_timeout [Numeric, nil] default seconds {#ask_and_wait}
      #   waits before giving up on an answer
      def initialize(channel:, default_timeout: nil)
        @channel         = channel
        @default_timeout = default_timeout
        @outstanding     = {}
        @counter         = 0
        @mutex           = Mutex.new
        @on_initiative   = nil
        @consumer        = nil
        @running         = false
        @closing         = false
      end

      # Ask the human a question, asynchronously.
      #
      # @param content [String] the question text
      # @param choices [Array<String>, nil] optional multiple-choice options
      # @param default [String, nil] value to use when the human answers empty
      # @return [Question] a handle whose {Question#answer} waits for the reply
      def ask(content, choices: nil, default: nil)
        question = register(content, choices, default)
        @channel.deliver(ChannelMessage.new(id: question.id, content: render(question)))
        ensure_consumer
        question
      end

      # Ask and block for the answer — the synchronous boundary a pipeline step
      # needs. Returns the human's answer, or the default (nil when none) if no
      # answer arrives within +timeout+.
      #
      # @param content [String] the question text
      # @param timeout [Numeric, nil] seconds to wait; nil = wait indefinitely
      # @return [String, nil]
      def ask_and_wait(content, timeout: @default_timeout, **)
        ask(content, **).answer(timeout: timeout)
      end

      # Register a handler for inbound messages that answer no outstanding
      # question — the human acting as a peer (raising something unprompted)
      # rather than replying.
      #
      # @yield [ChannelMessage] the unsolicited message
      # @return [self]
      def on_initiative(&block)
        @on_initiative = block
        self
      end

      # Stop the background consumer and close the channel.
      # @return [void]
      def close
        @mutex.synchronize { @closing = true }
        @channel.close
        @consumer&.join(1)
        @consumer = nil
      end

      # Remove a question from the outstanding set so a later, unrelated answer
      # cannot claim it. Called by {Question#answer} on timeout.
      #
      # @param question [Question]
      # @return [void]
      def expire(question)
        @mutex.synchronize { @outstanding.delete(question.id) }
      end

      private

      def register(content, choices, default)
        @mutex.synchronize do
          id = (@counter += 1)
          @outstanding[id] = Question.new(
            id: id, content: content, choices: choices, default: default, interviewer: self
          )
        end
      end

      # Lazily start the single consumer thread. It runs only while questions are
      # outstanding, so it stops on its own once every ask has been answered or
      # has timed out; the next {#ask} restarts it. (An always-on loop for idle,
      # unprompted human input is future work.) Starting and stopping both flip
      # +@running+ under the mutex, so a restart never races a shutdown.
      def ensure_consumer
        @mutex.synchronize do
          return if @running

          @running  = true
          @consumer = Thread.new { consume }
        end
      end

      def consume
        until stop?
          message = @channel.receive(timeout: POLL_INTERVAL)
          message ? dispatch(message) : sleep(POLL_INTERVAL)
        end
      rescue ClosedQueueError
        @mutex.synchronize { @running = false }
      end

      # Decide, atomically, whether the consumer should stop: when closing or
      # when nothing is outstanding. Flipping +@running+ here (under the same lock
      # {#ensure_consumer} uses) closes the window where a fresh ask could think a
      # consumer is still alive while this one is exiting.
      def stop?
        @mutex.synchronize do
          next false unless @closing || @outstanding.empty?

          @running = false
          true
        end
      end

      # Resolve the question this message answers, or route it as initiative.
      def dispatch(message)
        question = claim(message)
        if question
          question.resolve(interpret(message.content, question))
        else
          @on_initiative&.call(message)
        end
      end

      # The outstanding question this message answers: an explicit +in_reply_to+
      # when the channel provides one, otherwise the oldest outstanding question.
      # A correlated id that names no outstanding question matches nothing (the
      # message becomes initiative).
      def claim(message)
        reply_to = message.in_reply_to
        @mutex.synchronize do
          id = if reply_to.nil?
                 @outstanding.keys.min
               elsif @outstanding.key?(reply_to)
                 reply_to
               end
          id ? @outstanding.delete(id) : nil
        end
      end

      # Turn a raw human reply into an answer: fall back to the default on an
      # empty reply, and map a bare number to its choice. Always returns a String
      # so a genuine empty answer is never confused with a timeout (which is nil).
      def interpret(text, question)
        default = question.default
        text = default if empty_answer?(text) && !default.nil?
        resolve_choice(text.to_s, question.choices)
      end

      def empty_answer?(text)
        text.nil? || text.empty?
      end

      def render(question)
        return question.content unless question.choices&.any?

        numbered = question.choices.each_with_index.map { |choice, i| "  #{i + 1}. #{choice}" }
        [question.content, *numbered].join("\n")
      end

      def resolve_choice(text, choices)
        return text unless choices&.any?
        return text unless text.match?(/\A\d+\z/)

        index = text.to_i - 1
        index.between?(0, choices.size - 1) ? choices[index] : text
      end
    end

    # A pending question handed to the human. It carries the question's text and
    # options and acts as a one-shot future for the human's answer.
    class Question
      # @return [Integer] correlation id, unique within an Interviewer
      attr_reader :id
      # @return [String] the question text
      attr_reader :content
      # @return [Array<String>, nil] multiple-choice options, if any
      attr_reader :choices
      # @return [String, nil] value used when the human answers empty / times out
      attr_reader :default

      def initialize(id:, content:, choices: nil, default: nil, interviewer: nil)
        @id          = id
        @content     = content
        @choices     = choices
        @default     = default
        @interviewer = interviewer
        @mailbox     = Thread::Queue.new
      end

      # Deliver the human's (already interpreted) answer. Called by the
      # Interviewer's consumer.
      #
      # @param answer [String]
      # @return [void]
      def resolve(answer)
        @mailbox.push(answer)
      end

      # Block up to +timeout+ seconds for the human's answer. On timeout, expire
      # the question and return the default (nil when there is none) — this is how
      # "the human may never answer" surfaces to the caller.
      #
      # @param timeout [Numeric, nil] seconds to wait; nil = wait indefinitely
      # @return [String, nil]
      def answer(timeout: nil)
        result = timeout ? @mailbox.pop(timeout: timeout) : @mailbox.pop
        return result unless result.nil?

        @interviewer&.expire(self)
        @default
      end
    end
  end
end
