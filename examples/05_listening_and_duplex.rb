#!/usr/bin/env ruby
# frozen_string_literal: true

# Always-on listening + the duplex boundary.
#
# Earlier demos had the network ask the human questions. Here nobody asks the
# human anything — yet a listening Cyborg still hears them. `converse` puts the
# Cyborg in always-on listen mode: a background reader captures whatever the
# human types and routes it to peers by @mention (no mention => broadcast). The
# peers' replies come *back* to the human's channel automatically, because a
# Cyborg delivers inbound bus traffic to its channel (the output half of the
# duplex). Neither direction is wired by this demo — both live in the library.
#
# The human's "keystrokes" are scripted here (a StringIO) so the demo runs
# deterministically; in a real session this is your live terminal.
#
#   ruby examples/05_listening_and_duplex.rb

require "stringio"

# Prefer the local robot_lab checkout (with the latest fixes: serve/respond_to_tasks)
# over any installed gem, so the demo runs from a fresh monorepo checkout.
core_lib = File.expand_path("../../robot_lab/lib", __dir__)
$LOAD_PATH.unshift(core_lib) if File.directory?(core_lib)

require "robot_lab"
require_relative "../lib/robot_lab/cyborg"

Cyborg   = RobotLab::Cyborg
Terminal = RobotLab::Cyborg::Channel::Terminal

bus = TypedBus::MessageBus.new

# What the human types, unprompted, over time.
keystrokes = StringIO.new(<<~INPUT)
  @ops what's the current status?
  heads up everyone, deploying at 15:00
INPUT

you = Cyborg.new(name: "you", bus: bus, channel: Terminal.new(input: keystrokes, output: $stdout, name: "network"))

# Two key-free robot peers that serve bus tasks (respond_to_tasks — no LLM call),
# cooperating on the same bus as the human.
RobotLab.build(name: "ops",    bus: bus).respond_to_tasks { |_m| "all systems green" }
RobotLab.build(name: "deploy", bus: bus).respond_to_tasks { |_m| "roger, holding for go/no-go" }

# Start listening: unprompted human input is now routed by @mention; replies come
# back on the channel on their own.
you.converse(peers: %w[ops deploy])

# Let the background reader consume the scripted input and the replies land.
sleep 1.0
you.unlisten
