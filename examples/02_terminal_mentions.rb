#!/usr/bin/env ruby
# frozen_string_literal: true

# Addressing peers by @mention, driven by the library Conversation.
#
# A live human (a Cyborg on the terminal channel) shares a bus with several
# peers. Address them by mentioning them — "@name" — anywhere in a message, as
# many as you like; the whole message is fanned out to everyone you mention. A
# message with NO mention broadcasts to every peer.
#
# The addressing/fan-out/broadcast logic lives in RobotLab::Cyborg::Conversation
# now, not here. Replies come back to your terminal on their own: a Cyborg
# delivers inbound bus traffic to its channel (the output half of the duplex),
# so this demo never has to poll or render replies.
#
# @assistant is a real LLM robot (Ollama) that cooperates via #serve — the
# one-call symmetric responder. @analyst and @scribe are key-free canned peers.
# Set OLLAMA_API_BASE/OLLAMA_MODEL, or run without Ollama and just use the canned
# peers (@assistant will simply not answer).
#
#   ruby examples/02_terminal_mentions.rb
#   # then type:  @analyst and @scribe: status?
#   #             @assistant one-line haiku about deploys
#   #             @quit

require "logger"

# Prefer the local robot_lab checkout (with serve/respond_to_tasks) over any
# installed gem, so the demo runs from a fresh monorepo checkout.
core_lib = File.expand_path("../../robot_lab/lib", __dir__)
$LOAD_PATH.unshift(core_lib) if File.directory?(core_lib)

require "robot_lab"
require_relative "../lib/robot_lab/cyborg"

Cyborg   = RobotLab::Cyborg
Channel  = RobotLab::Cyborg::Channel

RubyLLM.configure do |c|
  c.ollama_api_base = ENV.fetch("OLLAMA_API_BASE", "http://localhost:11434/v1")
  c.logger          = Logger.new(File::NULL)
end
RobotLab.configure { |c| c.logger = Logger.new(File::NULL) }

# A canned automated peer: a Channel whose "human" is a block.
class Autobot < Channel
  def initialize(&reply)
    @reply = reply
    @inbox = Thread::Queue.new
    super()
  end

  def correlates? = true
  def deliver(message) = message.question? ? @inbox.push(reply_to(message)) : message
  def receive(timeout: nil) = timeout ? @inbox.pop(timeout: timeout) : @inbox.pop
  def close = @inbox.close

  private

  def reply_to(message)
    Cyborg::ChannelMessage.new(content: @reply.call(message.content), in_reply_to: message.id, kind: :answer)
  end
end

bus = TypedBus::MessageBus.new

# The live human. Its terminal labels inbound lines by their sender.
you = Cyborg.new(name: "you", bus: bus, channel: Channel::Terminal.new(name: "network"))

# A real LLM robot that serves bus tasks — the symmetric counterpart to how the
# Cyborg answers its human. One call, no hand-wired on_message.
RobotLab.build(name: "assistant", bus: bus, provider: "ollama",
               model: ENV.fetch("OLLAMA_MODEL", "qwen3.6"),
               system_prompt: "You are a concise teammate. Answer in 1-2 sentences.").serve

# Two key-free canned peers.
Cyborg.new(name: "analyst", bus: bus, channel: Autobot.new { |_q| "error rate is 0.2% over the last hour." })
Cyborg.new(name: "scribe",  bus: bus, channel: Autobot.new { |_q| "noted — logged to the record." })

chat = Cyborg::Conversation.new(cyborg: you, peers: %w[assistant analyst scribe])

you.tell("Mention peers with @name (one or more, anywhere); no mention broadcasts to all. " \
         "Known: @assistant, @analyst, @scribe. (@quit to exit)")

# The human drives the read loop; replies arrive on their own via the channel.
loop do
  message = you.channel.receive
  break if message.nil?

  line = message.content.strip
  next if line.empty?
  break if line == "@quit"

  chat.route(line)
end
