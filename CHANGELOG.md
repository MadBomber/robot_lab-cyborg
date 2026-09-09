# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.8] - 2026-09-09

Released in lockstep with `robot_lab` core v0.2.8: this gem now resolves the released core gem from RubyGems instead of the local sibling checkout (local-path development remains available via `BUNDLE_GEMFILE=Gemfile.local`). Also in this release: 17 reek false positives annotated inline, reek added to the development bundle, gem lifecycle tasks moved to asgard, and the release `Gemfile` no longer overrides `robot_lab` with the local checkout.

### Fixed (from the design/architecture review)
- **Consumer no longer wedges on a handler error.** An exception in an
  `on_initiative`/channel path used to kill the Interviewer's consumer thread and
  hang every future ask; it is now caught (recorded in `Interviewer#last_error`)
  and the loop keeps serving. *(A1)*
- **Inbound bus tasks no longer block the poller.** A Cyborg answers an inbound
  task on its own thread, so a slow or absent human never stalls bus intake, and
  the default no longer deadlocks. *(A2)*
- **No more mis-attributed answers on a dumb channel.** On a channel that can't
  correlate replies (`Channel#correlates? == false`, e.g. a terminal), questions
  are *serialized* — one on the wire at a time — and an answer resolves that
  active question. A `Terminal` now honors `receive(timeout:)` (via
  `wait_readable`), so timeouts, `close`, and expiry actually work. *(A3, A4)*
- **Shared memory no longer leaks across runs.** `attach_memory`/`detach_memory`
  make the target explicit, and access is thread-safe. *(A5)*
- Core `RobotLab::Robot::BusMessaging` synchronizes its message counter/outbox,
  and gains `respond_to_tasks`/`serve` so a **Robot** auto-answers bus tasks the
  way a Cyborg does — man/machine peers are now symmetric on the bus. *(A6, B1)*

### Added
- **Duplex to the human's channel.** Inbound bus messages/replies are now
  delivered to the human's channel (`Cyborg#tell` for the output direction);
  `ChannelMessage` carries `sender`/`kind`/`at` so a terminal can label who is
  speaking and only prompt on questions. *(B2, B5)*
- **Always-on listening.** `Cyborg#listen`/`converse` keep reading the channel
  with no question outstanding, so a human can address the network unprompted;
  their input arrives via `on_human`. *(B3)*
- **`Conversation`** — `@mention` addressing, multi-mention fan-out, and
  no-mention broadcast now live in the library (`Cyborg#converse`), not in
  example code. Replies flow back via the duplex. *(B4)*
- **Typed/validated answers** — `Cyborg#ask(validate:, retries:)` plus
  `ask_int`/`ask_confirm` re-ask on bad input and return coerced values. *(C)*
- **Presence** — `online!`/`away!`/`offline!`/`available?`; an offline human
  declines inbound tasks immediately so the network can route around/escalate.
  *(B8)*
- `Cyborg#ask_async` returns the pending `Question` for non-blocking waits — the
  primitive a durable/suspendable human step would persist (see README, *Durable
  human steps*, for the intended `robot_lab-durable` integration — *B7*).

### Changed
- Split reaching the human into two concerns: **`Channel`** (the *means* — a
  dumb bidirectional pipe: `deliver` out, `receive` in) and **`Interviewer`**
  (the *process* that conducts the ask over a channel). `$stdin`/`$stdout` now
  live only inside `Channel::Terminal`; `Cyborg` depends on an injected
  `channel:` and no longer takes `input:`/`output:`.
  - `Interviewer::Terminal` / `Interviewer::Scripted` moved to
    `Channel::Terminal` / `Channel::Scripted`. `Cyborg.new` takes `channel:`
    instead of `interviewer:` (an `interviewer:` may still be injected for full
    control).
  - Read the questions a Scripted human was shown via `cyborg.channel.asked`
    (was `cyborg.interviewer.asked`).

### Added
- **Asynchronous asking.** A human's answer may be the next inbound message, a
  later one, or never. `Interviewer#ask` now returns a `Question` (a one-shot
  future); `Cyborg#ask_async` exposes it. The synchronous `Cyborg#ask` /
  `Interviewer#ask_and_wait` wait with an optional timeout.
- **Reply correlation.** Inbound messages carry an optional `in_reply_to` so a
  rich transport (Slack threads, email) resolves the exact question; a bare
  terminal falls back to oldest-outstanding (FIFO).
- **Bounded waiting.** `Cyborg.new(ask_timeout:)` and per-call `timeout:` give a
  slow or absent human a deadline, after which the answer is the default (or nil).
- `Cyborg#on_human` — surfaces unsolicited human messages (initiative) that
  answer no outstanding question. (Routing initiative onto the bus is future work.)

## [0.1.0] - 2026-07-24

### Added
- `RobotLab::Cyborg` — a human peer worker that joins a RobotLab network at the
  same level as the robots. It reuses `RobotLab::Robot::BusMessaging`, so its bus
  behavior is identical to a robot's, but requires no LLM, model, or API key.
  - **Receives tasking** as a pipeline step (`network.task :name, cyborg`) via the
    `call`/`run` member contract, and over the bus (inbound messages are surfaced
    to the human and answered, with optional `auto_reply`).
  - **Issues tasking** to other members with `assign` (bus) and `delegate` (sync or
    async, returning a `RobotResult` / `DelegationFuture`).
  - **Shares memory** with the network via `remember` / `recall`.
- `RobotLab::Cyborg::Interviewer` — the pluggable human interface, with
  `Terminal` (injectable IO) and `Scripted` (tests/automation) implementations.
- Registers itself with core via `RobotLab.register_extension(:cyborg, …)`.
- Minitest suite covering the interviewers, the network-member contract and shared
  memory, the bus task/reply round-trip, and delegation.

[Unreleased]: https://github.com/MadBomber/robot_lab-cyborg/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/MadBomber/robot_lab-cyborg/releases/tag/v0.1.0
