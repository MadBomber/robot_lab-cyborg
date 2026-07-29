# robot_lab-cyborg

A [RobotLab](https://github.com/MadBomber/robot_lab) extension gem that puts a **human** into the network as a peer worker.

Robots on a RobotLab network are LLM-backed workers. A **`Cyborg`** is a *human*-backed worker that sits at exactly the same level as the robots: it registers as a network task, speaks on the same [TypedBus](https://github.com/MadBomber/typed_bus) channels, reads and writes the same shared memory, **receives tasking** (as a pipeline step and as bus messages), and **issues tasking** to the other members — humans and robots alike.

```ruby
require "robot_lab"
require "robot_lab/cyborg"

dewayne = RobotLab::Cyborg.new(name: "dewayne")

network = RobotLab.create_network(name: "release") do
  task :draft,   writer_robot, depends_on: :none
  task :approve, dewayne,      depends_on: [:draft]   # the human signs off
end

network.run(message: "Draft the release notes")
```

A `Cyborg` reuses `RobotLab::Robot::BusMessaging` verbatim, so its bus behavior is byte-for-byte identical to a robot's. It deliberately does **not** subclass `Robot`: a human needs no LLM, no model, and no API key. The human *is* the "model," reached across an injectable **`Channel`** (the *means* — terminal today, Slack/email/web later) by an **`Interviewer`** (the *process* that conducts the asynchronous ask-and-answer).

## Navigation

- [Getting Started](getting_started.md) — installation, creating a Cyborg, pipeline steps, bus messaging, running the bundled examples
- [How It Works](how_it_works.md) — the Channel/Interviewer split, correlation vs. serialization, the consumer thread, the duplex channel, presence, memory, the network-member contract, delegation
- [API Reference](api_reference.md) — every public class and method, grouped by concern
- [Building Custom Channels](custom_channels.md) — bridging a Cyborg to Slack, email, a web form, or any other transport

## At a Glance

| | |
|---|---|
| **Core class** | `RobotLab::Cyborg` — a human peer worker |
| **Bus behavior** | Identical to `Robot`'s — reuses `RobotLab::Robot::BusMessaging` |
| **Reaches the human via** | An injectable `Channel` (`Terminal` by default, `Scripted` for tests, or your own) |
| **Conducts the interaction via** | `Interviewer` — async ask/answer, question correlation, serialization on dumb channels |
| **Network roles** | Pipeline step (`task :name, cyborg`), bus peer (`assign`/`delegate`), shared-memory participant (`remember`/`recall`) |
| **Presence** | `online!` / `away!` / `offline!` / `available?` |
| **Multi-peer chat** | `Conversation` — `@mention` addressing, no-mention broadcast |
| **Typed answers** | `ask`, `ask_int`, `ask_confirm`, `ask(validate:, retries:)` |
| **Dependency** | `robot_lab ~> 0.2, >= 0.2.6` |

## Why a Cyborg, Not Just a Human-Shaped Robot?

A `Robot` is built around an LLM chat: model, provider, tokens, a `ruby_llm` chat object. None of that applies to a human. Rather than force a human through `Robot`'s LLM-shaped constructor and stub out everything that doesn't apply, `Cyborg` is a separate, smaller class that:

- Includes only the one piece of `Robot` it genuinely needs and shares byte-for-byte — `BusMessaging` (send/receive over `TypedBus`, spawn, bus poller wiring).
- Replaces "call the model" with "ask a human," via an injectable `Channel` + `Interviewer` pair instead of a `ruby_llm` chat.
- Still satisfies the same *network member* contract (`call`/`run`) so it is a drop-in peer anywhere a `Robot` is expected — a pipeline `task`, a `delegate` target, a `spawn`-style bus peer.

## Links

- [RobotLab Core](https://github.com/MadBomber/robot_lab)
- [RubyGems](https://rubygems.org/gems/robot_lab-cyborg)
- [GitHub](https://github.com/MadBomber/robot_lab-cyborg)
- [Changelog](https://github.com/MadBomber/robot_lab-cyborg/blob/main/CHANGELOG.md)
