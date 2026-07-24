# frozen_string_literal: true

require "robot_lab"

require_relative "cyborg/version"
require_relative "cyborg/channel"

module RobotLab
  # A Cyborg is a *human* peer worker on a RobotLab::Network.
  #
  # Robots on a network are LLM-backed workers; a Cyborg is a human-backed one.
  # It is a peer at the same level as the robots: it registers as a network task,
  # speaks on the same TypedBus channels, reads and writes the same shared
  # memory, receives tasking (both as a pipeline step and as bus messages), and
  # issues tasking to the other members — humans and robots alike.
  #
  # It reuses RobotLab::Robot::BusMessaging verbatim, so its bus behavior is
  # byte-for-byte identical to a robot's. It deliberately does *not* subclass
  # Robot, because a human needs no LLM, no model, and no API key — the human is
  # the "model," reached across an injectable {Channel} (the *means* — terminal
  # now, Slack/email/web later) by an {Interviewer} (the *process* that conducts
  # the asynchronous ask-and-answer).
  #
  # @example A human peer in a network pipeline
  #   dewayne = RobotLab::Cyborg.new(name: "dewayne")
  #   network = RobotLab.create_network(name: "review") do
  #     task :draft,  writer_robot,  depends_on: :none
  #     task :approve, dewayne,      depends_on: [:draft]   # the human signs off
  #   end
  #   network.run(message: "Draft the release notes")
  #
  # @example Peers messaging over a shared bus
  #   bus     = TypedBus::MessageBus.new
  #   analyst = RobotLab.build(name: "analyst", bus: bus)
  #   dewayne = RobotLab::Cyborg.new(name: "dewayne", bus: bus)
  #   analyst.send_message(to: :dewayne, content: "Approve deploy? (yes/no)")
  #   # dewayne's human is prompted; the answer is sent back as a reply
  #
  class Cyborg
    include RobotLab::Robot::BusMessaging

    # Raised for Cyborg-specific misuse (e.g. issuing a bus task with no bus).
    class Error < StandardError; end

    # @return [String] the peer's unique name — also its bus channel name
    attr_reader :name

    # @return [TypedBus::MessageBus, nil] the shared bus, if any
    attr_reader :bus

    # @return [Hash] outbox of messages this peer has sent, keyed by message key
    attr_reader :outbox

    # @return [Channel] the injectable means by which this peer reaches its human
    attr_reader :channel

    # @return [Interviewer] the process conducting this peer's human interaction
    attr_reader :interviewer

    # @return [RobotLab::Memory] the peer's own (standalone) memory
    attr_reader :memory

    # Create a human peer.
    #
    # @param name [String] unique name (and bus channel name) for this peer
    # @param bus [TypedBus::MessageBus, nil] shared bus to join immediately
    # @param channel [Channel, nil] means of reaching the human (default: a
    #   terminal channel on $stdin/$stdout)
    # @param interviewer [Interviewer, nil] the interaction process (default: a
    #   fresh Interviewer over +channel+)
    # @param auto_reply [Boolean] reply to inbound bus tasks automatically
    # @param memory [RobotLab::Memory, nil] standalone memory (default: fresh)
    # @param ask_timeout [Numeric, nil] seconds to wait for the human before
    #   giving up on an answer (nil = wait indefinitely)
    def initialize(name:, bus: nil, channel: nil, interviewer: nil,
                   auto_reply: true, memory: nil, ask_timeout: nil)
      @name = name.to_s

      # ivars the BusMessaging mixin expects to find already initialized
      @bus               = bus
      @bus_poller        = nil
      @private_bus_poller = nil
      @bus_poller_group  = :default
      @bus_subscriber_id = nil
      @message_counter   = 0
      @outbox            = {}
      @bus_mutex         = Mutex.new
      @message_handler   = method(:handle_incoming)

      @auto_reply    = auto_reply
      @ask_timeout   = ask_timeout
      @presence      = :online
      @on_task       = nil
      @on_human      = nil
      @inbox         = []
      @inbox_mutex   = Mutex.new
      @state_mutex   = Mutex.new
      @shared_memory = nil
      @memory        = memory || Memory.new
      @channel       = channel || Channel::Terminal.new(name: @name)
      @interviewer   = interviewer || Interviewer.new(channel: @channel, default_timeout: @ask_timeout)
      @interviewer.on_initiative { |message| handle_human_initiative(message) }

      setup_bus_channel if @bus
    end

    # --- Network member interface (peer-level, same as a Robot) --------------

    # SimpleFlow step interface. The network calls this when the pipeline reaches
    # the human; the human performs the step and the result flows downstream just
    # like any robot's RobotResult.
    #
    # @param result [SimpleFlow::Result] incoming pipeline result
    # @return [SimpleFlow::Result]
    def call(result)
      run_context = extract_run_context(result)
      started = clock
      robot_result = run(run_context[:message], network_memory: run_context[:network_memory])
      robot_result.duration = clock - started

      result
        .with_context(@name.to_sym, robot_result)
        .continue(robot_result)
    rescue StandardError => e
      error_result = build_result("Error: #{e.class}: #{e.message}")
      result
        .with_context(@name.to_sym, error_result)
        .continue(error_result)
    end

    # Perform one unit of work by asking the human, and return a RobotResult so
    # the human is interchangeable with a robot everywhere (pipeline steps,
    # Robot#delegate, etc.).
    #
    # @param message [String, nil] the task / prompt for the human
    # @param network_memory [RobotLab::Memory, nil] shared memory when in a network
    # @param memory [RobotLab::Memory, nil] explicit memory override
    # @return [RobotResult]
    def run(message = nil, network_memory: nil, memory: nil, **_kwargs)
      active = memory || network_memory || @memory
      attach_memory(network_memory) if network_memory

      answer = with_writer(active) { ask(message.to_s) }
      build_result(answer)
    end

    # --- Human interface ------------------------------------------------------

    # Ask this peer's human a question and block for the answer. This is the
    # synchronous boundary the network relies on (pipeline steps, bus tasks); the
    # underlying interview is asynchronous. Returns the default (nil when none)
    # if no answer arrives within +timeout+.
    #
    # @param question [String]
    # @param choices [Array<String>, nil]
    # @param default [String, nil]
    # @param timeout [Numeric, nil] seconds to wait (default: this peer's ask_timeout)
    # @param validate [#call, nil] a validator: return a coerced value when the
    #   answer is acceptable, or nil to reject and re-ask
    # @param retries [Integer] extra attempts allowed when validation rejects
    # @return [Object, nil] the human's answer (coerced when validated)
    def ask(question, choices: nil, default: nil, timeout: @ask_timeout, validate: nil, retries: 2)
      attempt = 0
      loop do
        answer = @interviewer.ask_and_wait(question, choices: choices, default: default, timeout: timeout)
        return answer if validate.nil? || answer.nil?

        value = validate.call(answer)
        return value unless value.nil?

        attempt += 1
        return default if attempt > retries

        tell(%(Sorry, I couldn't use "#{answer}". Please try again.))
      end
    end

    # Ask for an integer, re-asking until the human gives a parseable number.
    # @return [Integer, nil]
    def ask_int(question, **)
      ask(question, validate: ->(a) { Integer(a.to_s.strip, exception: false) }, **)
    end

    # Ask a yes/no question, returning true/false (nil if never answered).
    # @return [Boolean, nil]
    def ask_confirm(question, **)
      ask(question, choices: %w[yes no], validate: method(:parse_bool), **)
    end

    # Ask this peer's human a question without blocking, returning the pending
    # {Question} so the caller can wait on it later, on its own terms.
    #
    # @param question [String]
    # @param choices [Array<String>, nil]
    # @param default [String, nil]
    # @return [Question]
    def ask_async(question, choices: nil, default: nil)
      @interviewer.ask(question, choices: choices, default: default)
    end

    # Register a callback fired after the human answers an inbound bus task.
    #
    # @yield [message, answer] the inbound RobotMessage and the human's answer
    # @return [self]
    def on_task(&block)
      @on_task = block
      self
    end

    # Register a callback fired when the human sends something unprompted — a
    # message over the channel that answers no outstanding question. This is the
    # human-initiates-into-the-network path; a {Conversation} turns these into
    # addressed bus messages, or handle them yourself here.
    #
    # @yield [ChannelMessage] the unsolicited human message
    # @return [self]
    def on_human(&block)
      @on_human = block
      self
    end

    # Say something to the human over the channel (network -> human), unprompted —
    # the output half of the duplex. Use this to surface notices, or let a
    # {Conversation} route peer replies here automatically.
    #
    # @param text [String]
    # @param kind [Symbol] :notice | :message | :question
    # @return [self]
    def tell(text, kind: :notice)
      @channel.deliver(ChannelMessage.new(content: text.to_s, kind: kind))
      self
    end

    # Start an interactive {Conversation}: the human addresses peers by @mention
    # (no mention broadcasts to all), replies come back on the channel. Returns
    # the started Conversation.
    #
    # @param peers [Array<String, Symbol>] addressable member names
    # @return [Conversation]
    def converse(peers: [])
      Conversation.new(cyborg: self, peers: peers).start
    end

    # Start always-on listening: keep reading the channel even when no question is
    # outstanding, so the human can speak to the network unprompted at any time.
    # Their input arrives via {#on_human}. Idempotent.
    #
    # @return [self]
    def listen
      @interviewer.listen
      self
    end

    # Stop always-on listening.
    # @return [self]
    def unlisten
      @interviewer.unlisten
      self
    end

    # --- Presence / availability ---------------------------------------------

    # @return [Symbol] :online, :away, or :offline
    attr_reader :presence

    # Whether this human peer will take work now. The network can check this
    # before delegating and route around or escalate for an absent human.
    #
    # @return [Boolean]
    def available?
      @state_mutex.synchronize { @presence != :offline }
    end

    # Mark the human present and taking work.
    # @return [self]
    def online!
      @state_mutex.synchronize { @presence = :online }
      self
    end

    # Mark the human present but slow to respond (still asked; caller should use a
    # generous timeout).
    # @return [self]
    def away!
      @state_mutex.synchronize { @presence = :away }
      self
    end

    # Mark the human unavailable. Inbound bus tasks are declined immediately
    # instead of waiting on a human who isn't there.
    # @return [self]
    def offline!
      @state_mutex.synchronize { @presence = :offline }
      self
    end

    # --- Issuing tasks to other members --------------------------------------

    # Issue a task to another member over the bus (fire-and-forget; the reply,
    # if any, is correlated into {#outbox}). Alias for the robot idiom
    # +send_message+, named for how a human hands off work.
    #
    # @param to [String, Symbol] target member's name/channel
    # @param task [String, Hash] the task payload
    # @return [RobotMessage] the sent message
    def assign(to:, task:)
      send_message(to: to, content: task)
    end

    # Delegate a task to another member and get a RobotResult back, synchronously
    # or asynchronously. Works against robots and cyborgs alike, because both
    # respond to +run+.
    #
    # @param to [#run] the member to delegate to (Robot or Cyborg)
    # @param task [String] the task message
    # @param async [Boolean] when true, returns a DelegationFuture immediately
    # @return [RobotResult, DelegationFuture]
    def delegate(to:, task:, async: false, **)
      if async
        future = DelegationFuture.new(robot_name: to.name, delegated_by: @name)
        delegator = @name
        Thread.new do
          result = to.run(task, **)
          result.delegated_by = delegator
          future.resolve!(result)
        rescue StandardError => e
          future.reject!(e)
        end
        future
      else
        result = to.run(task, **)
        result.delegated_by = @name
        result
      end
    end

    # --- Shared memory --------------------------------------------------------

    # Write to the active memory (the network's shared memory when in a network,
    # otherwise this peer's own memory). Other members see it immediately.
    #
    # @param key [Object]
    # @param value [Object]
    # @return [Object] value
    def remember(key, value)
      current_memory.set(key, value)
      value
    end

    # Read from the active memory, optionally blocking until another member
    # writes the key.
    #
    # @param key [Object]
    # @param wait [Boolean, Numeric] false, true, or seconds to wait
    # @return [Object, nil]
    def recall(key, wait: false)
      current_memory.get(key, wait: wait)
    end

    # Attach this peer to a shared memory — what {#remember}/{#recall} target. A
    # network run attaches automatically; call {#detach_memory} to return to this
    # peer's own standalone memory (so it doesn't keep writing to a finished
    # network's memory).
    #
    # @param mem [RobotLab::Memory]
    # @return [self]
    def attach_memory(mem)
      @state_mutex.synchronize { @shared_memory = mem }
      self
    end

    # Detach from any shared memory, returning to standalone memory.
    # @return [self]
    def detach_memory
      @state_mutex.synchronize { @shared_memory = nil }
      self
    end

    # --- Inspection -----------------------------------------------------------

    # Inbound bus messages this peer has received, oldest first.
    #
    # @return [Array<RobotMessage>]
    def inbox
      @inbox_mutex.synchronize { @inbox.dup }
    end

    # @return [Hash]
    def to_h
      {
        name: @name,
        kind: :cyborg,
        bus: @bus ? true : nil,
        channel: @channel.class.name
      }.compact
    end

    private

    def clock
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def current_memory
      @state_mutex.synchronize { @shared_memory } || @memory
    end

    # Run the block with +memory+'s current writer set to this peer, restoring it
    # afterward. A no-op for memories that don't track a writer.
    def with_writer(memory)
      return yield unless memory.respond_to?(:current_writer=)

      previous = memory.current_writer if memory.respond_to?(:current_writer)
      memory.current_writer = @name
      yield
    ensure
      memory.current_writer = previous if memory.respond_to?(:current_writer=)
    end

    # Route an inbound bus delivery (runs on the bus poller drain thread; arity-1
    # handler => the poller auto-acks). A reply is shown to the human as a peer
    # message. A fresh task is surfaced to the human *and answered off this thread*
    # (see {#respond_to_task}) so a slow or absent human never blocks bus intake.
    def handle_incoming(message)
      @inbox_mutex.synchronize { @inbox << message }
      deliver_to_human(message, kind: :message) if message.reply?
      return if message.reply?

      respond_to_task(message)
    end

    # Answer an inbound task on its own thread. The poller returns immediately;
    # the human's answer (bounded by ask_timeout) is replied when it arrives. An
    # offline human declines right away rather than leaving the sender hanging.
    def respond_to_task(message)
      unless available?
        send_reply(to: message.from, content: "(#{@name} is unavailable)", in_reply_to: message.key) if @auto_reply && @bus
        return
      end

      Thread.new do
        answer = ask(task_prompt(message))
        send_reply(to: message.from, content: answer, in_reply_to: message.key) if @auto_reply && @bus && answer
        @on_task&.call(message, answer)
      rescue StandardError => e
        warn "[Cyborg #{@name}] inbound task failed: #{e.class}: #{e.message}"
      end
    end

    # Show an inbound network message to the human over the channel (the output
    # half of the duplex). Best-effort — a channel error must not break intake.
    def deliver_to_human(message, kind:)
      @channel.deliver(ChannelMessage.new(content: message_body(message), sender: message.from, kind: kind))
    rescue StandardError
      nil
    end

    # An inbound channel message that answered no outstanding question: the human
    # speaking as a peer, unprompted. Surface it to the on_human handler.
    def handle_human_initiative(message)
      @on_human&.call(message)
    end

    def task_prompt(message)
      "#{message.from} asks: #{message_body(message)}"
    end

    def message_body(message)
      content = message.content
      content.is_a?(Hash) ? content.map { |k, v| "#{k}: #{v}" }.join("\n") : content.to_s
    end

    # Interpret a yes/no answer as a boolean, or nil when it is neither.
    def parse_bool(answer)
      case answer.to_s.strip.downcase
      when "y", "yes", "true", "1"  then true
      when "n", "no", "false", "0"  then false
      end
    end

    # Build a RobotResult from the human's text, shaped exactly like a robot's
    # so `result.reply` works and downstream steps can't tell the difference.
    def build_result(text)
      RobotResult.new(
        robot_name: @name,
        output: [TextMessage.new(role: "assistant", content: text.to_s)]
      )
    end

    # Pull the message and shared memory out of the pipeline result. The first
    # step's value is the run-context Hash; later steps' value is a RobotResult.
    def extract_run_context(result)
      run_params = result.context[:run_params] || {}
      value = result.value
      message = case value
                when Hash then value[:message] || run_params[:message]
                when RobotResult then value.last_text_content
                when String then value
                when NilClass then run_params[:message]
                else value.to_s
                end

      { message: message, network_memory: run_params[:network_memory] }
    end
  end
end

require_relative "cyborg/interviewer"
require_relative "cyborg/conversation"

RobotLab.register_extension(:cyborg, RobotLab::Cyborg) if RobotLab.respond_to?(:register_extension)
