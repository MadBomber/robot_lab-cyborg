# frozen_string_literal: true

module RobotLab
  class Cyborg
    # A message crossing the human boundary, in either direction.
    #
    # Outbound (network -> human): the Interviewer stamps +id+ (the question it
    # is tracking) and +content+ (the rendered question). Inbound (human ->
    # network): the Channel fills +content+ and, when the transport can correlate
    # a reply to a specific question (a Slack thread, an email In-Reply-To), sets
    # +in_reply_to+ to that question's id. A dumb transport (a terminal) leaves
    # +in_reply_to+ nil and the Interviewer falls back to FIFO matching.
    ChannelMessage = Data.define(:id, :content, :in_reply_to) do
      def initialize(content:, id: nil, in_reply_to: nil)
        super(id:, content: content.to_s, in_reply_to:)
      end
    end

    # A Channel is the *means* by which a Cyborg reaches its human: a dumb,
    # bidirectional pipe. It knows how to {#deliver} a message *out* to the human
    # and to surface messages the human sends *in* — nothing more. It has no
    # concept of a "question" or an "answer"; correlating replies to questions is
    # the {Interviewer}'s job (the *process*), not the channel's.
    #
    # The same two-method API backs a terminal today and Slack, email, SMS, or a
    # web form later — each is just a different Channel. Because the boundary is
    # the injected channel, +$stdin+/+$stdout+ live *only* inside {Terminal};
    # nothing else in the Cyborg assumes a terminal.
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
      #
      # @param timeout [Numeric, nil] seconds to wait; nil = block indefinitely
      # @return [ChannelMessage, nil]
      def receive(timeout: nil)
        raise NotImplementedError, "#{self.class} must implement #receive"
      end

      # Release any resources. Default: no-op.
      def close; end

      # Terminal-backed channel: the human is at a keyboard. This is the only
      # place +$stdin+/+$stdout+ are assumed; inject StringIO in tests.
      class Terminal < Channel
        # @param input [IO] stream to read the human's messages from
        # @param output [IO] stream to write messages to the human on
        # @param name [String] label shown in the prompt, e.g. "[dewayne]"
        def initialize(input: $stdin, output: $stdout, name: "cyborg")
          @input = input
          @output = output
          @name = name
          super()
        end

        def deliver(message)
          @output.puts "\n[#{@name}] #{message.content}"
          @output.print "> "
          @output.flush
          message
        end

        # A terminal carries no correlation metadata, so +in_reply_to+ is left
        # nil and the Interviewer matches FIFO. A nil line means EOF.
        def receive(timeout: nil)
          return nil unless (line = @input.gets)

          ChannelMessage.new(content: line.chomp)
        end
      end

      # Scripted channel: canned human answers for tests, automation, and replay.
      #
      # Each delivered question is paired with the next scripted answer *at
      # delivery time* and stamped with that question's id, so correlation is
      # exact and deterministic. When the script runs dry, delivered questions
      # simply go unanswered — modeling a human who never replies — and the
      # Interviewer's timeout takes over. Every question shown is recorded in
      # {#asked} so tests can assert on what the human saw.
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

        def deliver(message)
          @mutex.synchronize do
            @asked << message.content
            @inbox.push(ChannelMessage.new(content: @answers.shift, in_reply_to: message.id)) unless @answers.empty?
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
