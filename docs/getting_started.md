# Getting Started

## Prerequisites

- Ruby 3.2+ (per the gemspec's `required_ruby_version`)
- `robot_lab` `~> 0.2`, `>= 0.2.6` — `robot_lab-cyborg` needs the `respond_to_tasks`/`serve` and shared bus-mutex additions to `RobotLab::Robot::BusMessaging` that landed at that version, and `RobotLab::Memory#current_writer=`.
- `robot_lab` must be `require`d before `robot_lab/cyborg` (`Cyborg` includes `RobotLab::Robot::BusMessaging` and calls `RobotLab.register_extension`, both of which must already be defined).

## Installation

Add to your `Gemfile`:

```ruby
gem "robot_lab"
gem "robot_lab-cyborg"
```

Then:

```sh
bundle install
```

Or install directly:

```sh
gem install robot_lab-cyborg
```

## Creating a Human Peer

```ruby
require "robot_lab"
require "robot_lab/cyborg"

# By default, talks to a terminal on $stdin/$stdout.
dewayne = RobotLab::Cyborg.new(name: "dewayne")
```

`Cyborg.new` accepts:

| Keyword | Default | Purpose |
|---|---|---|
| `name:` | *(required)* | unique peer name — also the bus channel name |
| `bus:` | `nil` | a `TypedBus::MessageBus` to join immediately |
| `channel:` | a `Channel::Terminal` on `$stdin`/`$stdout` | the means of reaching the human |
| `interviewer:` | a fresh `Interviewer` over `channel:` | the process conducting the ask (rarely overridden directly — inject `channel:` instead) |
| `auto_reply:` | `true` | reply to inbound bus tasks automatically once the human answers |
| `memory:` | a fresh `RobotLab::Memory` | this peer's own (standalone) memory, used outside a network |
| `ask_timeout:` | `nil` (wait indefinitely) | seconds to wait for the human before falling back to a default |

## A Human as a Pipeline Step

The human is interchangeable with a robot anywhere a network member is expected — it satisfies the same `call`/`run` contract a `Robot` does:

```ruby
writer = RobotLab.build(name: "writer", template: :writer)

network = RobotLab.create_network(name: "release") do
  task :draft,   writer,  depends_on: :none
  task :approve, dewayne, depends_on: [:draft]   # the human signs off
end

result = network.run(message: "Draft the release notes")
result.value.reply   # => the human's answer, same shape as a robot's RobotResult#reply
```

When the pipeline reaches the human's task, the network calls `dewayne.call(pipeline_result)`, which extracts the incoming message, calls `dewayne.ask(message)`, and wraps the answer in a `RobotResult` so downstream steps can't tell a human answered instead of a robot.

## Peers Messaging Over a Shared Bus

Robots and cyborgs talk to each other by name over one shared bus — the same `TypedBus::MessageBus` a `Robot` would join via `RobotLab.build(bus:)`:

```ruby
bus     = TypedBus::MessageBus.new
analyst = RobotLab.build(name: "analyst", bus: bus)
dewayne = RobotLab::Cyborg.new(name: "dewayne", bus: bus)

# The robot asks the human a question; the human's answer comes back as a reply.
analyst.send_message(to: :dewayne, content: "Approve the deploy? (yes/no)")

# The human issues work to the robot, too.
dewayne.assign(to: :analyst, task: "Summarize today's error budget.")
```

`send_message`/`send_reply`/`on_message` all come from `RobotLab::Robot::BusMessaging`, which `Cyborg` includes — see [How It Works](how_it_works.md#network-member-and-bus-contracts) for the one important caveat about overriding `on_message` on a `Cyborg`.

## Shared Memory

```ruby
dewayne.remember(:decision, "ship it")   # visible to every member
dewayne.recall(:sentiment, wait: 30)     # block until a robot writes it
```

Inside a network run, `remember`/`recall` target the network's shared memory automatically (`attach_memory` is called for you); outside a network, they fall back to the peer's own standalone `memory:`.

## A Minimal, Key-Free Example

Inject a `Channel::Scripted` to run the human side end-to-end with no live terminal and no API keys:

```ruby
require "robot_lab"
require "robot_lab/cyborg"

Scripted = RobotLab::Cyborg::Channel::Scripted

approver = RobotLab::Cyborg.new(name: "approver", channel: Scripted.new(["approved: ship it"]))

network = RobotLab.create_network(name: "release") do
  task :approve, approver, depends_on: :none
end

result = network.run(message: "Approve the v1.0 release notes?")
puts result.value.reply                # => "approved: ship it"
puts approver.channel.asked.first       # => "Approve the v1.0 release notes?"
```

## Bundled Examples

The gem ships five runnable demos, one feature area each — see the [examples/](https://github.com/MadBomber/robot_lab-cyborg/tree/main/examples) directory:

| Example | Demonstrates | Needs a live human? | Needs an LLM? |
|---|---|---|---|
| `01_human_in_the_network.rb` | Pipeline step, bus messaging between two humans, shared memory | No (scripted) | No |
| `02_terminal_mentions.rb` | Live `@mention` addressing via `Conversation`, a real Ollama robot cooperating via `#serve` | Yes | Optional (canned peers work without it) |
| `03_robot_interviews_cyborg.rb` | The interview run the *other* way — an LLM robot interviews the human via `delegate`, typed intake (`ask_confirm`/`ask_int`) | Yes | Yes (Ollama) |
| `04_presence_and_availability.rb` | `online!`/`away!`/`offline!`, an offline human declining immediately, bounded-timeout escalation | No (scripted) | No |
| `05_listening_and_duplex.rb` | Always-on `listen`: the human speaks unprompted, replies come back on the channel | No (scripted) | No |

```sh
ruby examples/01_human_in_the_network.rb
ruby examples/04_presence_and_availability.rb
ruby examples/05_listening_and_duplex.rb

# Examples 2 and 3 use a real robot on Ollama (ollama pull qwen3.6; override with
# OLLAMA_MODEL / OLLAMA_API_BASE). In example 2 the canned peers still work
# without it — only @assistant needs Ollama.
ruby examples/02_terminal_mentions.rb        # then type: @analyst and @scribe: status?
ruby examples/03_robot_interviews_cyborg.rb  # the robot asks you the questions
```

## Development

```sh
bin/setup                    # install dependencies
bundle exec rake test        # run tests
bundle exec rake quality     # tests + RuboCop + Flog + Flay
bin/console                  # IRB with the gem loaded
```

## Key Constraints

- `robot_lab` must be `require`d before `robot_lab/cyborg` — see Prerequisites above.
- `$stdin`/`$stdout` are only ever touched inside `Channel::Terminal`; every other part of the gem is transport-agnostic.
- A human step holds a thread while it waits for an answer (`ask`/`ask_and_wait` block the calling thread; `ask_async` does not — see [How It Works](how_it_works.md#asking-asynchronously)). There is currently no way to persist a pending question across a process restart — see the [Durable Human Steps](how_it_works.md#roadmap-durable-human-steps) roadmap note.
- Calling `on_message`, `respond_to_tasks`, or `serve` (all inherited from `BusMessaging`) on a `Cyborg` replaces its built-in inbound-task handling — see [How It Works](how_it_works.md#network-member-and-bus-contracts).
