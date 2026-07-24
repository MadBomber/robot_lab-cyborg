# frozen_string_literal: true

module RobotLab
  class Cyborg
    # A Conversation turns a listening {Cyborg} into an interactive participant in
    # a multi-peer network. It reads the human's unprompted messages and routes
    # each by @mention:
    #
    # - "@name ..." (one or more mentions, anywhere in the line) fans the whole
    #   message out to every mentioned peer.
    # - a line with no mention is a broadcast to every known peer.
    #
    # Replies come *back* to the human's channel automatically — the Cyborg
    # delivers inbound bus traffic to the channel (the output half of the duplex)
    # — so a Conversation only has to handle the human -> network direction.
    #
    # The addressing convention that used to live in example code now lives here,
    # so every channel (terminal, Slack, ...) gets it for free.
    #
    # @example
    #   you  = RobotLab::Cyborg.new(name: "you", bus: bus)
    #   chat = RobotLab::Cyborg::Conversation.new(cyborg: you, peers: %w[analyst scribe]).start
    #   # human types "hey @analyst and @scribe: status?" -> both are tasked
    class Conversation
      MENTION = /@(\w+)/ # every @name in a message, in order of first appearance

      # @return [Array<String>] names this conversation can address
      attr_reader :peers

      # @param cyborg [Cyborg] the human peer whose channel/bus this drives
      # @param peers [Array<String, Symbol>] known addressable member names
      def initialize(cyborg:, peers: [])
        @cyborg = cyborg
        @peers  = peers.map(&:to_s)
      end

      # Add an addressable peer by name.
      # @return [self]
      def add_peer(name)
        @peers << name.to_s unless @peers.include?(name.to_s)
        self
      end

      # Begin routing the human's unprompted input by @mention (always-on listen).
      # Idempotent.
      # @return [self]
      def start
        @cyborg.on_human { |message| route(message.content) }
        @cyborg.listen
        self
      end

      # Stop routing (winds down listening).
      # @return [self]
      def stop
        @cyborg.unlisten
        self
      end

      # Route one line of human input onto the bus. Unknown mentions are reported
      # back to the human; a line mentioning only unknown peers is not sent.
      #
      # @param line [String]
      # @return [Array<String>] the peers the message was sent to
      def route(line)
        line = line.to_s.strip
        return [] if line.empty?

        mentioned  = line.scan(MENTION).flatten.uniq
        recipients = recipients_for(mentioned)
        return [] if recipients.nil?

        recipients.each { |name| @cyborg.assign(to: name, task: line) }
        recipients
      end

      private

      # Resolve the recipients for a line, or nil when there is nothing to send
      # (after telling the human why).
      def recipients_for(mentioned)
        unknown = mentioned - @peers
        @cyborg.tell("No such peer: #{unknown.map { |n| "@#{n}" }.join(', ')}") unless unknown.empty?

        recipients = mentioned.empty? ? @peers : (mentioned & @peers)
        return recipients unless recipients.empty?

        @cyborg.tell("No known peer to address. Known: #{roster}.")
        nil
      end

      def roster
        @peers.map { |name| "@#{name}" }.join(", ")
      end
    end
  end
end
