# robot_lab-cyborg

A [RobotLab](https://github.com/MadBomber/robot_lab) extension gem that puts a **human** into the network as a peer worker.

Robots on a RobotLab network are LLM-backed workers. A **Cyborg** is a *human*-backed worker that sits at the same level as the robots: it registers as a network task, speaks on the same [TypedBus](https://github.com/MadBomber/typed_bus) channels, reads and writes the same shared memory, **receives tasking** (as a pipeline step and as bus messages), and **issues tasking** to the other members — humans and robots alike.

A Cyborg reuses `RobotLab::Robot::BusMessaging` verbatim, so its bus behavior is byte-for-byte identical to a robot's. It deliberately does **not** subclass `Robot`: a human needs no model and no API key. The human is the "model," reached across an injectable **`Channel`** (the *means* — terminal now, Slack/email/web later) by an **`Interviewer`** (the *process* that conducts the ask).

## Installation

Add to your Gemfile:

```ruby
gem "robot_lab"
gem "robot_lab-cyborg"
```

## Usage

```ruby
require "robot_lab"
require "robot_lab/cyborg"

# A human peer. By default it talks to a terminal; inject a Channel to
# reach the human over a web form, a queue, a chat app, or a test.
dewayne = RobotLab::Cyborg.new(name: "dewayne")
```

### A human as a pipeline step

The human is interchangeable with a robot anywhere a member is expected:

```ruby
writer = RobotLab.build(name: "writer", template: :writer)

network = RobotLab.create_network(name: "release") do
  task :draft,   writer,  depends_on: :none
  task :approve, dewayne, depends_on: [:draft]   # the human signs off
end

network.run(message: "Draft the release notes")
```

### Peers messaging over a shared bus

Robots and cyborgs talk to each other by name over one shared bus:

```ruby
bus     = TypedBus::MessageBus.new
analyst = RobotLab.build(name: "analyst", bus: bus)
dewayne = RobotLab::Cyborg.new(name: "dewayne", bus: bus)

# The robot asks the human a question; the human's answer comes back as a reply.
analyst.send_message(to: :dewayne, content: "Approve the deploy? (yes/no)")

# The human issues work to the robot, too.
dewayne.assign(to: :analyst, task: "Summarize today's error budget.")
```

### Shared memory

```ruby
dewayne.remember(:decision, "ship it")   # visible to every member
dewayne.recall(:sentiment, wait: 30)     # block until a robot writes it
```

### Channels and the Interviewer

Reaching the human is split into two concerns:

- A **`Channel`** is the *means* — a dumb bidirectional pipe with two jobs: `deliver` a message **out** to the human, and surface messages the human sends **in**. It knows nothing about questions or answers. This is the injection point; `$stdin`/`$stdout` live only inside `Channel::Terminal`.
- An **`Interviewer`** is the *process* — it conducts the interaction over whatever channel is injected. Asking is **always asynchronous**: the human's answer may be the next inbound message, a later one, or never. So `ask` delivers the question and returns a `Question` you can wait on with a timeout; a background consumer matches answers to questions (by the channel's correlation id when it has one, else oldest-first) and routes anything unsolicited as human *initiative*.

Built-in channels:

- `Channel::Terminal` — the human at a keyboard (the default); IO is injectable.
- `Channel::Scripted` — canned answers in order, with exact correlation (tests, automation, replay).
- `Channel` — the abstract base; subclass it (implement `deliver`/`receive`) to bridge to Slack, email, a web UI, or a task queue.

A channel that can tie an answer back to its question (Slack threads, email) reports `correlates? == true`, and the Interviewer lets several questions be outstanding at once. A dumb channel (a bare terminal) reports `false`, and the Interviewer **serializes** — one question on the wire at a time — so an answer is never mis-attributed.

```ruby
scripted = RobotLab::Cyborg::Channel::Scripted.new(["yes", "ship it"])
bot      = RobotLab::Cyborg.new(name: "dewayne", channel: scripted)

# Give a slow or absent human a bounded wait:
oncall   = RobotLab::Cyborg.new(name: "oncall", ask_timeout: 30)   # nil answer if no reply
```

### Cooperating in a network

- **Symmetric bus membership.** A Cyborg answers inbound bus tasks out of the box; a Robot opts in with one call — `robot.serve` (run each task through the model and reply) or `robot.respond_to_tasks { |m| ... }`. Both are first-class responders.
- **Duplex.** Inbound messages/replies are shown to the human on their channel automatically; `cyborg.tell("...")` pushes a line out yourself.
- **Addressing.** `cyborg.converse(peers: %w[analyst scribe])` starts a `Conversation`: the human addresses peers by `@mention` anywhere in a message (fan-out to all mentioned; **no mention broadcasts to everyone**), and replies come back on the channel.
- **Listening.** `converse`/`listen` keep reading the channel with no question pending, so the human can speak to the network unprompted (delivered via `on_human`).
- **Typed answers.** `ask_int`, `ask_confirm`, or `ask(validate:, retries:)` re-ask on bad input and return coerced values.
- **Presence.** `online!` / `away!` / `offline!` / `available?` — an offline human declines inbound tasks immediately, so the network can route around or escalate.

```ruby
you = RobotLab::Cyborg.new(name: "you", bus: bus)
you.converse(peers: %w[analyst scribe])         # @mention to address, no mention = broadcast
ready = you.ask_confirm("Deploy now?")          # => true / false
you.away!                                        # still asked, but use a bounded timeout
```

#### Durable human steps (roadmap)

A human step currently holds a thread while it waits. `ask_async` returns the pending `Question` without blocking — the primitive a durable integration would persist. The intended path is to store a pending decision through **`robot_lab-durable`** (and `robot_lab-to`'s `DecisionManager`) so a human decision survives a process restart and doesn't pin a thread. Per-peer cryptographic identity/attribution (signed events) is the complementary trust direction, on top of the existing per-message `sender`/`from`.

## Examples

Runnable demos in [`examples/`](examples) — one feature area each:

- `01_human_in_the_network.rb` — a human as a pipeline step, peers messaging over a bus, shared memory (network → human). Key-free.
- `02_terminal_mentions.rb` — a **live** human addresses peers by `@mention` via the library `Conversation` (fan-out, and no-mention broadcast); replies return on their own through the duplex. Includes a real **LLM robot** (`@assistant`, Ollama) cooperating via `serve`, plus key-free canned peers.
- `03_robot_interviews_cyborg.rb` — the Interviewer the *other* way round: an **LLM robot** (Ollama) interviews the human via `delegate`, starting with a **typed** intake (`ask_confirm`/`ask_int`, which re-ask on bad input), then builds a categorized profile.
- `04_presence_and_availability.rb` — routing to a peer who's actually there: `online`/`away`/`offline`, an offline human declining immediately, and a bounded-timeout escalation. Key-free.
- `05_listening_and_duplex.rb` — always-on `listen`: the human speaks to the network **unprompted** and replies come back on the channel — both directions handled by the library. Key-free.

```bash
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

After checking out the repo, run `bin/setup` to install dependencies. Then run `rake test` to run the tests, or `rake quality` to run the full gate (tests, RuboCop, Flog, Flay). `bin/console` gives an interactive prompt.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
