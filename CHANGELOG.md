# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
