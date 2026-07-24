#!/usr/bin/env ruby
# frozen_string_literal: true

# A robot interviews a cyborg (the Interviewer, the other way round).
#
# Examples 1 and 2 had the human drive. Here the *robot* drives: an LLM-backed
# RobotLab robot (ProfileBot, on a local Ollama model) conducts an interview to
# learn as much as the human is willing to share, then classifies them across
# several categories. Each question the robot invents is delegated to the Cyborg,
# whose Interviewer conducts it on the terminal and hands the answer back — so
# the robot never touches $stdin/$stdout; the Cyborg's Interviewer is the whole
# bridge between the robot's intent and the person at the keyboard.
#
# You can answer each question, type "skip" to pass on one, or "done" to end the
# interview early. The robot builds the profile from whatever you chose to share.
#
# Requires a running Ollama with the model pulled:  ollama pull qwen3.6
# Override with OLLAMA_MODEL / OLLAMA_API_BASE if yours differ.
#
#   ruby examples/03_robot_interviews_cyborg.rb

require "logger"
# Prefer the local robot_lab checkout (with the latest fixes) over any installed gem.
core_lib = File.expand_path("../../robot_lab/lib", __dir__)
$LOAD_PATH.unshift(core_lib) if File.directory?(core_lib)

require "robot_lab"
require_relative "../lib/robot_lab/cyborg"

Cyborg  = RobotLab::Cyborg
Channel = RobotLab::Cyborg::Channel

OLLAMA_API_BASE = ENV.fetch("OLLAMA_API_BASE", "http://localhost:11434/v1")
OLLAMA_MODEL    = ENV.fetch("OLLAMA_MODEL", "qwen3.6")
MAX_QUESTIONS   = Integer(ENV.fetch("MAX_QUESTIONS", "5"))

ENDING_WORDS   = %w[done stop quit exit].freeze
SKIPPING_WORDS = %w[skip pass].freeze

RubyLLM.configure do |c|
  c.ollama_api_base = OLLAMA_API_BASE
  c.logger          = Logger.new(File::NULL)
end
RobotLab.configure { |c| c.logger = Logger.new(File::NULL) }

# The interviewer robot. Its system prompt fixes the categories it is building
# toward and keeps it to one question at a time so each turn maps cleanly onto a
# single Interviewer ask.
robot = RobotLab.build(
  name: "ProfileBot",
  provider: "ollama",
  model: OLLAMA_MODEL,
  system_prompt: <<~PROMPT
    You are ProfileBot, a warm, concise interviewer. Your goal is to learn as much
    as the person is willing to share so you can later classify them across these
    categories: technical proficiency, professional role, communication style,
    interests, and decision-making style.

    Rules:
    - Ask exactly ONE short, friendly question per turn.
    - Output only the question itself — no preamble, numbering, or commentary.
    - Build on what they have already told you; do not repeat a topic.
    - Do not classify or summarize until you are explicitly asked to.
  PROMPT
)

# The human peer. Its terminal shows each question under a "[ProfileBot]" label,
# since in this demo everything the human hears comes from the robot.
you = Cyborg.new(name: "you", channel: Channel::Terminal.new(name: "ProfileBot"), ask_timeout: 300)

# Ask the human one question by delegating it to the Cyborg. The Cyborg's
# Interviewer delivers it over the terminal channel and returns the answer.
def interview_turn(robot, human, question)
  robot.delegate(to: human, task: question).reply.to_s.strip
end

you.tell("Hi! I'd like to ask you a few questions.")

# A short *typed* intake first — the Cyborg validates and re-asks on bad input.
unless you.ask_confirm("Ready to begin?")
  you.tell("No problem — maybe another time.")
  exit
end
years = you.ask_int("Roughly how many years have you worked in your field?")
you.tell("Thanks. Answer freely from here, say \"skip\" to pass, or \"done\" to finish.")

# Seed the robot with the structured intake so it shows up in the profile.
robot.run(%(Context: they have about #{years || "an unstated number of"} years of experience. Acknowledge in one word.))

question       = robot.run("Ask your first question.").reply.to_s.strip
answers_given  = 0

until answers_given >= MAX_QUESTIONS
  answer = interview_turn(robot, you, question)
  break if ENDING_WORDS.include?(answer.downcase)

  answers_given += 1
  feedback = if answer.empty? || SKIPPING_WORDS.include?(answer.downcase)
               "They preferred to skip that. Ask a different, lighter question."
             elsif answers_given >= MAX_QUESTIONS
               %(They answered: "#{answer}". That was the final question — reply with just "Thanks!")
             else
               %(They answered: "#{answer}". Ask your next question.)
             end
  # Feeding the answer back both records it in the robot's memory and produces
  # the next question (the last one is discarded once the quota is reached).
  question = robot.run(feedback).reply.to_s.strip
end

puts "\n  …ProfileBot is building your profile…"
profile = robot.run(<<~PROMPT).reply.to_s.strip
  The interview is complete. Using only what they told you, build their profile.
  For each category give your classification and a one-line reason grounded in
  their answers; write "insufficient information" where they did not reveal enough.

  Technical proficiency:
  Professional role:
  Communication style:
  Interests:
  Decision-making style:

  End with a one-sentence overall summary.
PROMPT

you.tell("Here is the profile I built from what you shared:\n\n#{profile}")
