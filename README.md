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

```ruby
scripted = RobotLab::Cyborg::Channel::Scripted.new(["yes", "ship it"])
bot      = RobotLab::Cyborg.new(name: "dewayne", channel: scripted)

# Give a slow or absent human a bounded wait:
oncall   = RobotLab::Cyborg.new(name: "oncall", ask_timeout: 30)   # nil answer if no reply
```

## Examples

Runnable demos in [`examples/`](examples):

- `01_human_in_the_network.rb` — a scripted human as a pipeline step, peers messaging over a bus, and shared memory (network → human). Key-free.
- `02_terminal_mentions.rb` — a **live** human on the terminal channel who addresses peers by mention: type `@name your message` and it is routed to that peer over the bus, whose reply comes back to your terminal (human → network). Addresses a real **LLM robot** (`@assistant`, a RobotLab robot on a local Ollama model) alongside key-free canned peers — you address all of them the same way.

```bash
ruby examples/01_human_in_the_network.rb

# Example 2 needs a running Ollama with the model pulled (ollama pull qwen3.6);
# override with OLLAMA_MODEL / OLLAMA_API_BASE. The canned peers still work
# without it — only @assistant requires Ollama.
ruby examples/02_terminal_mentions.rb   # then type: @assistant write a haiku about deployment
```

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then run `rake test` to run the tests, or `rake quality` to run the full gate (tests, RuboCop, Flog, Flay). `bin/console` gives an interactive prompt.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
