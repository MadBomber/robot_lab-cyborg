#!/usr/bin/env ruby
# frozen_string_literal: true

# Human-in-the-network demo.
#
# A Cyborg is a human peer worker. It reaches its human across an injectable
# Channel (the *means*: terminal now, Slack/email/web later). This example
# injects a Scripted channel so it runs end-to-end without a live human — omit
# `channel:` to get the default terminal channel and answer the prompts yourself.
#
#   ruby examples/01_human_in_the_network.rb

# Prefer the local robot_lab checkout (with the latest fixes) over any installed gem.
core_lib = File.expand_path("../../robot_lab/lib", __dir__)
$LOAD_PATH.unshift(core_lib) if File.directory?(core_lib)

require "robot_lab"
require_relative "../lib/robot_lab/cyborg"

Scripted = RobotLab::Cyborg::Channel::Scripted

# --- 1. A human as a pipeline step ------------------------------------------
# The human is interchangeable with a robot: it registers as a network task and
# its answer flows downstream like any RobotResult.

approver = RobotLab::Cyborg.new(name: "approver", channel: Scripted.new(["approved: ship it"]))

network = RobotLab.create_network(name: "release") do
  task :approve, approver, depends_on: :none
end

result = network.run(message: "Approve the v1.0 release notes?")
puts "Pipeline result : #{result.value.reply}"
puts "Human was asked : #{approver.channel.asked.first}"

# --- 2. Two peers messaging over a shared bus -------------------------------
# A robot would normally be on this bus too; here both peers are humans to keep
# the example key-free. The message plumbing is identical either way.

bus  = TypedBus::MessageBus.new
lead = RobotLab::Cyborg.new(name: "lead", bus: bus, channel: Scripted.new([]))
# oncall just needs to exist on the bus to receive the task and reply; it is
# addressed by name (:oncall), so no local reference is kept.
RobotLab::Cyborg.new(name: "oncall", bus: bus, channel: Scripted.new(["yes, go ahead"]))

msg = lead.assign(to: :oncall, task: "Safe to deploy right now?")

# Wait for the async round-trip (task out, human answer, reply back).
50.times do
  break if lead.outbox[msg.key][:status] == :replied

  sleep 0.02
end

reply = lead.outbox[msg.key][:replies].first
puts "\nlead asked oncall : Safe to deploy right now?"
puts "oncall replied    : #{reply&.content}"

# --- 3. Shared memory --------------------------------------------------------
lead.remember(:decision, "deploy at 15:00")
puts "\nShared memory :decision => #{lead.recall(:decision)}"
