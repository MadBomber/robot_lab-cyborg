#!/usr/bin/env ruby
# frozen_string_literal: true

# Terminal Cyborg with @mention addressing — now talking to a real LLM robot.
#
# A *live* human (a Cyborg on the default terminal Channel) shares one bus with:
#   - @assistant — a RobotLab robot backed by a local Ollama model (qwen3.6)
#   - @analyst, @scribe — canned auto-responders (key-free stand-ins)
#
# Address peers by mentioning them — "@name" — anywhere in a message, as many as
# you like. The whole message (mentions and all) is fanned out to every peer you
# mention, and each replies back to your terminal. A message with *no* mention is
# a broadcast: it goes to every peer in the network. @assistant actually thinks
# (via Ollama) and answers in its own words; the others reply instantly — you
# cannot tell, from the addressing, which peers are human, canned, or LLM-backed.
#
# Requires a running Ollama with the model pulled:  ollama pull qwen3.6
# Override with OLLAMA_MODEL / OLLAMA_API_BASE if yours differ.
#
#   ruby examples/02_terminal_mentions.rb
#   # then type:  @assistant write a haiku about deployment
#   #             @analyst   what's our error rate?
#   #             @quit

require "logger"
require "robot_lab"
require_relative "../lib/robot_lab/cyborg"

Cyborg         = RobotLab::Cyborg
Channel        = RobotLab::Cyborg::Channel
ChannelMessage = RobotLab::Cyborg::ChannelMessage

OLLAMA_API_BASE = ENV.fetch("OLLAMA_API_BASE", "http://localhost:11434/v1")
OLLAMA_MODEL    = ENV.fetch("OLLAMA_MODEL", "qwen3.6")

RubyLLM.configure do |c|
  c.ollama_api_base = OLLAMA_API_BASE
  c.logger          = Logger.new(File::NULL)
end
RobotLab.configure { |c| c.logger = Logger.new(File::NULL) }

# Autobot: a canned automated peer — a Channel whose "human" is a block. Keeps
# @analyst/@scribe key-free and instant, and shows a Channel can back any kind
# of worker, not just a person.
class Autobot < Channel
  def initialize(&reply)
    @reply = reply
    @inbox = Thread::Queue.new
    super()
  end

  def deliver(message)
    @inbox.push(ChannelMessage.new(content: @reply.call(message.content), in_reply_to: message.id))
    message
  end

  def receive(timeout: nil)
    timeout ? @inbox.pop(timeout: timeout) : @inbox.pop
  end

  def close = @inbox.close
end

bus = TypedBus::MessageBus.new

# The live human. Bus identity "you"; the terminal labels incoming lines
# "[network]" so replies from other members read naturally.
you = Cyborg.new(name: "you", bus: bus, channel: Channel::Terminal.new(name: "network"))

# A real LLM robot on the same bus. A robot's default bus handler is a no-op, so
# we teach it to run each inbound task through the model and reply to the sender
# — the same task/reply contract the Cyborg fulfills for its human.
assistant = RobotLab.build(
  name: "assistant",
  bus: bus,
  provider: "ollama",
  model: OLLAMA_MODEL,
  system_prompt: "You are a helpful teammate in a group chat. Answer concisely, in 1-3 sentences."
)
assistant.on_message do |message|
  next if message.reply?

  answer = assistant.run(message.content).reply
  assistant.send_reply(to: message.from, content: answer, in_reply_to: message.key)
rescue StandardError => e
  assistant.send_reply(to: message.from, content: "(error: #{e.message})", in_reply_to: message.key)
end

# Everyone the human can address, by name (the robot alongside the auto-responders).
peers = {
  "assistant" => assistant,
  "analyst"   => Cyborg.new(name: "analyst", bus: bus,
                            channel: Autobot.new { |_question| "error rate is 0.2% over the last hour." }),
  "scribe"    => Cyborg.new(name: "scribe", bus: bus,
                            channel: Autobot.new { |_question| "noted — logged to the record." })
}

MENTION = /@(\w+)/ # every @name in the message, in order of first appearance

def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

# Show a line to the human — the channel's output direction (network -> human).
def tell(human, text)
  human.channel.deliver(ChannelMessage.new(content: text))
end

# Collect replies from a set of peers a message was fanned out to. Peers work
# concurrently (each on its own bus thread), so replies are shown as they arrive
# rather than in mention order — an instant canned peer need not wait on a slow
# LLM one. +pending+ maps peer name => the sent message's outbox key.
def collect_replies(human, pending, timeout: 180)
  started  = monotonic
  notified = false
  until pending.empty? || monotonic - started > timeout
    pending.select { |_name, key| human.outbox.dig(key, :status) == :replied }.each do |name, key|
      tell(human, "@#{name}: #{human.outbox[key][:replies].first&.content}")
      pending.delete(name)
    end
    if !notified && !pending.empty? && monotonic - started > 0.4
      puts "  …waiting on #{pending.keys.map { |n| "@#{n}" }.join(', ')}…"
      notified = true
    end
    sleep 0.05 unless pending.empty?
  end
  pending.each_key { |name| tell(human, "(@#{name} did not respond)") }
end

roster = peers.keys.map { |name| "@#{name}" }.join(", ")
tell(you, "Mention peers with @name (one or more, anywhere); no mention broadcasts to all. Known: #{roster}. (@quit to exit)")

loop do
  # The channel's input direction (human -> network): read the human's next line.
  message = you.channel.receive
  break if message.nil? # EOF

  line = message.content.strip
  next if line.empty?
  break if line == "@quit"

  mentioned = line.scan(MENTION).flatten.uniq

  if mentioned.empty?
    recipients = peers.keys # no mention -> broadcast to every peer
  else
    unknown = mentioned - peers.keys
    tell(you, "(no such peer: #{unknown.map { |n| "@#{n}" }.join(', ')})") unless unknown.empty?
    recipients = mentioned & peers.keys # only the known mentioned peers
    if recipients.empty?
      tell(you, "No known peer mentioned. Known: #{roster}.")
      next
    end
  end

  # Fan the whole message out to every recipient, then gather their replies.
  pending = recipients.to_h { |name| [name, you.assign(to: name, task: line).key] }
  collect_replies(you, pending)
end
