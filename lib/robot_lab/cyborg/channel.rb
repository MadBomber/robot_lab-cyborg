# frozen_string_literal: true

module RobotLab
  class Cyborg
    # A message crossing the human boundary, in either direction.
    #
    # Outbound (network -> human): the Interviewer/Cyborg stamps +content+ and a
    # +kind+ (:question for a prompt awaiting an answer, :message/:notice for
    # everything else) plus, when known, the +sender+ it is on behalf of.
    # Inbound (human -> network): the Channel fills +content+ and, when the
    # transport can correlate a reply to a specific question (a Slack thread, an
    # email In-Reply-To), sets +in_reply_to+ to that question's id. A dumb
    # transport (a bare terminal) leaves +in_reply_to+ nil.
    #
    # @!attribute id           [Integer, nil] question id this message carries/answers
    # @!attribute content      [String] the human-readable payload
    # @!attribute in_reply_to  [Integer, nil] id of the question an inbound answer replies to
    # @!attribute sender       [String, nil] who the message is from/for (for display)
    # @!attribute kind         [Symbol] :question | :answer | :message | :notice
    # @!attribute at           [Time] when the message was created
    ChannelMessage = Data.define(:id, :content, :in_reply_to, :sender, :kind, :at) do
      # :reek:ControlParameter -- nil at means "stamp with Time.now"; a default,
      # not a behavior switch.
      def initialize(content:, id: nil, in_reply_to: nil, sender: nil, kind: :message, at: nil)
        super(id:, content: content.to_s, in_reply_to:, sender:, kind:, at: at || Time.now)
      end

      # @return [Boolean] true when this is a prompt the human is expected to answer
      def question? = kind == :question
    end

    # A Channel is the *means* by which a Cyborg reaches its human: a dumb,
    # bidirectional pipe. It knows how to {#deliver} a message *out* to the human
    # and to surface messages the human sends *in* — nothing more. It has no
    # concept of a "question" or an "answer"; correlating replies to questions is
    # the {Interviewer}'s job (the *process*), not the channel's.
    #
    # The same small API backs a terminal today and Slack, email, SMS, or a web
    # form later — each is just a different Channel. Because the boundary is the
    # injected channel, +$stdin+/+$stdout+ live *only* inside {Terminal}; nothing
    # else in the Cyborg assumes a terminal.
    #
    # A channel that can tie an inbound answer back to the question it answers
    # (Slack threads, email In-Reply-To) reports {#correlates?} true; the
    # Interviewer then lets several questions be outstanding at once. A dumb
    # channel reports false, and the Interviewer serializes questions — one on the
    # wire at a time — so an answer is never mis-attributed.
    #
    # @abstract Subclass and implement {#deliver} and {#receive}.
    class Channel
      # Send a message out to the human (network -> human).
      #
      # @param message [ChannelMessage] the outbound message
      # @return [ChannelMessage] the delivered message
      def deliver(message)
        raise NotImplementedError, "#{self.class} must implement #deliver"
      end

      # Return the next message from the human (human -> network), waiting up to
      # +timeout+ seconds. Returns nil when nothing arrives in that window — nil
      # is transient ("not yet"), not "closed"; the Interviewer keeps polling.
      # Implementations MUST honor +timeout+ so the consumer can stay responsive
      # to shutdown and question expiry.
      #
      # @param timeout [Numeric, nil] seconds to wait; nil = block indefinitely
      # @return [ChannelMessage, nil]
      def receive(timeout: nil)
        raise NotImplementedError, "#{self.class} must implement #receive"
      end

      # Whether the transport tags inbound answers with the question they reply to
      # (sets +in_reply_to+). Dumb channels return false and get one-question-at-
      # a-time serialization from the Interviewer.
      #
      # @return [Boolean]
      def correlates? = false

      # Release any resources. Default: no-op.
      def close; end

      # Terminal-backed channel: the human is at a keyboard. This is the only
      # place +$stdin+/+$stdout+ are assumed; inject StringIO in tests.
      class Terminal < Channel
        # @param input [IO] stream to read the human's messages from
        # @param output [IO] stream to write messages to the human on
        # @param name [String] label shown when a message has no explicit sender
        def initialize(input: $stdin, output: $stdout, name: "cyborg")
          @input = input
          @output = output
          @name = name
          @write_mutex = Mutex.new
          super()
        end

        # Print the message. A :question is followed by a "> " prompt; other kinds
        # (inbound peer messages, notices) are not, so unsolicited traffic does not
        # spam the input cursor. Synchronized so concurrent deliveries (a question
        # and an inbound peer message) never interleave on screen.
        def deliver(message)
          @write_mutex.synchronize do
            @output.puts "\n[#{message.sender || @name}] #{message.content}"
            @output.print "> " if message.question?
            @output.flush
          end
          message
        end

        # Read a line, honoring +timeout+ so the consumer can poll for shutdown and
        # expiry. Uses IO.select on a real IO; a non-selectable stream (StringIO in
        # tests) returns immediately from #gets, which is equally responsive. A nil
        # line means EOF. A bare terminal carries no correlation, so +in_reply_to+
        # stays nil.
        def receive(timeout: nil)
          return nil if timeout && selectable? && !@input.wait_readable(timeout)
          return nil unless (line = @input.gets)

          ChannelMessage.new(content: line.chomp, kind: :answer)
        rescue IOError
          nil
        end

        private

        # Only a real IO can be waited on for readiness; a StringIO (tests) is not,
        # and #gets returns from it immediately anyway.
        def selectable? = @input.is_a?(IO)
      end

      # Scripted channel: canned human answers for tests, automation, and replay.
      #
      # Each delivered question is paired with the next scripted answer *at
      # delivery time* and stamped with that question's id, so correlation is exact
      # and deterministic (hence {#correlates?} is true). When the script runs dry,
      # delivered questions simply go unanswered — modeling a human who never
      # replies — and the Interviewer's timeout takes over. Every question shown is
      # recorded in {#asked} so tests can assert on what the human saw.
      class Scripted < Channel
        # @return [Array<String>] questions delivered so far, in order
        attr_reader :asked

        # @param answers [Array<String>, String] answers to return, in order
        def initialize(answers = [])
          @answers = Array(answers).dup
          @asked   = []
          @inbox   = Thread::Queue.new
          @mutex   = Mutex.new
          super()
        end

        def correlates? = true

        def deliver(message)
          # A scripted human answers questions; notices and inbound peer messages
          # are shown, not answered (and don't consume a scripted answer).
          return message unless message.question?

          @mutex.synchronize do
            @asked << message.content
            unless @answers.empty?
              @inbox.push(ChannelMessage.new(content: @answers.shift, in_reply_to: message.id, kind: :answer))
            end
          end
          message
        end

        def receive(timeout: nil)
          timeout ? @inbox.pop(timeout: timeout) : @inbox.pop
        end

        def close
          @inbox.close
        end
      end
    end
  end
end
