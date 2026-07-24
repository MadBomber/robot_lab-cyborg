#!/usr/bin/env ruby
# frozen_string_literal: true

# Presence & availability: routing work to a human who is actually there.
#
# A human peer publishes a presence — :online, :away, or :offline — that the
# network can use to route around or escalate for someone who isn't available,
# instead of blocking on a person who will never answer.
#
#   :online   takes work now
#   :away      still asked, but the caller should use a bounded timeout
#   :offline   declines inbound bus tasks immediately
#
# Key-free: the "humans" here are scripted, so the demo runs deterministically.
#
#   ruby examples/04_presence_and_availability.rb

# Prefer the local robot_lab checkout (with the latest fixes) over any installed gem.
core_lib = File.expand_path("../../robot_lab/lib", __dir__)
$LOAD_PATH.unshift(core_lib) if File.directory?(core_lib)

require "robot_lab"
require_relative "../lib/robot_lab/cyborg"

Cyborg   = RobotLab::Cyborg
Scripted = RobotLab::Cyborg::Channel::Scripted

bus = TypedBus::MessageBus.new

dispatcher = Cyborg.new(name: "dispatcher", bus: bus, channel: Scripted.new)
alice = Cyborg.new(name: "alice", bus: bus, channel: Scripted.new(["Approved — ship it.", "Signed off."])) # online
bob   = Cyborg.new(name: "bob",   bus: bus, channel: Scripted.new(["(bob should never be asked)"]))  # offline
sam   = Cyborg.new(name: "sam",   bus: bus, channel: Scripted.new, ask_timeout: 0.4)                 # away, never answers

bob.offline!
sam.away!

# Wait briefly for a reply to a sent task; return its text or nil.
def await_reply(peer, key, timeout: 3)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
  loop do
    entry = peer.outbox[key]
    return entry[:replies].first&.content if entry && entry[:status] == :replied
    return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

    sleep 0.02
  end
end

def ask_over_bus(dispatcher, name, task)
  message = dispatcher.assign(to: name, task: task)
  await_reply(dispatcher, message.key)
end

puts "Presence of each peer:"
[alice, bob, sam].each { |p| puts "  #{p.name.ljust(6)} #{p.presence}  (available? #{p.available?})" }

puts "\n1) Route to the first *available* peer among [bob, alice]:"
approver = [bob, alice].find(&:available?)
puts "   picked @#{approver.name} (bob is offline) -> asked over the bus"
puts "   @#{approver.name} says: #{ask_over_bus(dispatcher, approver.name, 'Approve the deploy?')}"

puts "\n2) Ask @bob anyway (offline) — declined immediately, no hanging:"
puts "   @bob replies: #{ask_over_bus(dispatcher, 'bob', 'Approve the deploy?')}"

puts "\n3) Ask @sam (away) with a 0.4s bound — times out, so escalate:"
if ask_over_bus(dispatcher, "sam", "Quick sign-off?").nil?
  puts "   @sam did not answer in time -> escalating to @alice"
  puts "   @alice says: #{ask_over_bus(dispatcher, 'alice', 'Quick sign-off?')}"
end
