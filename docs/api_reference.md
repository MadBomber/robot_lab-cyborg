# API Reference

Every public class and method in `robot_lab-cyborg`, grouped by concern. See [How It Works](how_it_works.md) for the concepts behind each one.

## `RobotLab::Cyborg`

### Constructor

#### `new(name:, bus: nil, channel: nil, interviewer: nil, auto_reply: true, memory: nil, ask_timeout: nil)`

| Parameter | Type | Default | Description |
|---|---|---|---|
| `name` | `String` | *(required)* | unique peer name — also the bus channel name |
| `bus` | `TypedBus::MessageBus`, `nil` | `nil` | shared bus to join immediately |
| `channel` | `Channel`, `nil` | `Channel::Terminal.new(name: name)` | means of reaching the human |
| `interviewer` | `Interviewer`, `nil` | `Interviewer.new(channel:, default_timeout: ask_timeout)` | the interaction process (inject `channel:` instead, in almost all cases) |
| `auto_reply` | `Boolean` | `true` | reply to inbound bus tasks automatically once the human answers |
| `memory` | `RobotLab::Memory`, `nil` | a fresh `Memory.new` | standalone memory used outside a network |
| `ask_timeout` | `Numeric`, `nil` | `nil` (wait indefinitely) | seconds to wait for the human before falling back to a default |

```ruby
dewayne = RobotLab::Cyborg.new(name: "dewayne")
dewayne = RobotLab::Cyborg.new(name: "dewayne", bus: bus, ask_timeout: 30)
```

### Attributes

| Reader | Type | Description |
|---|---|---|
| `name` | `String` | peer name / bus channel name |
| `bus` | `TypedBus::MessageBus`, `nil` | the shared bus, if any |
| `outbox` | `Hash` | messages this peer has sent, keyed by message key — `{status:, message:, replies:}` |
| `channel` | `Channel` | the injected means of reaching the human |
| `interviewer` | `Interviewer` | the process conducting this peer's human interaction |
| `memory` | `RobotLab::Memory` | this peer's own standalone memory |
| `presence` | `Symbol` | `:online`, `:away`, or `:offline` |

### Network Member Interface

#### `call(result) → SimpleFlow::Result`

The `SimpleFlow` step contract — invoked by the network when a pipeline reaches this peer's task. Extracts the message and shared memory from `result`, calls `#run`, and threads the resulting `RobotResult` back into the pipeline. Exceptions are caught and turned into an error-shaped `RobotResult` rather than raised.

#### `run(message = nil, network_memory: nil, memory: nil, **) → RobotResult`

Asks the human `message` and wraps the answer in a `RobotResult` — the contract that makes a `Cyborg` a valid `delegate`/pipeline target anywhere a `Robot` is. Attaches `network_memory` automatically when given.

### Asking the Human

#### `ask(question, choices: nil, default: nil, timeout: @ask_timeout, validate: nil, retries: 2) → Object, nil`

Blocks for the human's answer (or `default`/`nil` on timeout). `validate:` is called with the raw answer; return a coerced value to accept it, or `nil` to reject and re-ask (up to `retries` extra attempts, then fall back to `default`).

```ruby
cyborg.ask("Deploy now?")
cyborg.ask("Pick one", choices: %w[a b c])
cyborg.ask("Env?", validate: ->(a) { %w[dev prod].include?(a) ? a : nil })
```

#### `ask_int(question, **) → Integer, nil`

`ask` with a validator that re-asks until the human gives a parseable integer (`Integer(str, exception: false)`).

#### `ask_confirm(question, **) → Boolean, nil`

`ask` with `choices: %w[yes no]` and a validator mapping `y`/`yes`/`true`/`1` → `true`, `n`/`no`/`false`/`0` → `false` (case-insensitive).

#### `ask_async(question, choices: nil, default: nil) → Question`

Delivers the question and returns immediately with the pending `Question`, instead of blocking.

### Callbacks

#### `on_task(&block) → self`

Fires `block.call(message, answer)` after the human answers an inbound bus task.

#### `on_human(&block) → self`

Fires `block.call(channel_message)` when the human sends something unprompted — a channel message answering no outstanding question.

### Talking to the Human

#### `tell(text, kind: :notice) → self`

Pushes `text` out to the human over the channel, unprompted — the network → human half of the duplex.

#### `converse(peers: []) → Conversation`

Starts (`Conversation.new(cyborg: self, peers:).start`) and returns an interactive `Conversation`: the human addresses peers by `@mention`, replies return automatically.

#### `listen → self`

Keeps the interviewer's consumer alive with no question outstanding, so unprompted human input is captured as initiative. Idempotent.

#### `unlisten → self`

Stops always-on listening.

### Presence

#### `available? → Boolean`

`true` unless `presence == :offline`.

#### `online! → self`

Sets presence to `:online` (default) — taking work now.

#### `away! → self`

Sets presence to `:away` — still asked, but callers should use a bounded timeout.

#### `offline! → self`

Sets presence to `:offline` — inbound bus tasks are declined immediately instead of waiting on an absent human.

### Issuing Work to Other Members

#### `assign(to:, task:) → RobotMessage`

Fire-and-forget bus send — alias for `BusMessaging#send_message`. Correlate any reply later via `outbox[message.key]`.

#### `delegate(to:, task:, async: false, **) → RobotResult, DelegationFuture`

`to` may be a `Robot` or another `Cyborg` — anything responding to `#run`. Synchronous by default (blocks, returns a `RobotResult` stamped with `delegated_by`); `async: true` spawns a thread and returns a `RobotLab::DelegationFuture` immediately (`future.value` / `future.value(timeout:)` blocks later; raises `DelegationFuture::DelegationTimeout` on expiry).

### Shared Memory

#### `remember(key, value) → value`

Writes to the active memory (network shared memory when attached, else this peer's own).

#### `recall(key, wait: false) → Object, nil`

Reads from the active memory. `wait:` may be `false`, `true` (block indefinitely), or a `Numeric` numbers of seconds.

#### `attach_memory(mem) → self`

Points `remember`/`recall` at `mem` — a network run does this automatically when it starts.

#### `detach_memory → self`

Returns to this peer's own standalone memory.

### Inspection

#### `inbox → Array<RobotMessage>`

Inbound bus messages received so far, oldest first (a defensive copy).

#### `to_h → Hash`

`{name:, kind: :cyborg, bus: true|nil, channel: "Channel::ClassName"}.compact`

### Bus Methods (via `RobotLab::Robot::BusMessaging`)

`Cyborg` includes `RobotLab::Robot::BusMessaging` verbatim, gaining `send_message`, `send_reply`, `spawn`, `with_bus`, and `assign_bus_poller`. **Do not call `on_message`, `respond_to_tasks`, or `serve` on a `Cyborg`** — all three replace the inbound message handler wholesale, which disables the built-in ask/auto-reply flow. See [How It Works](how_it_works.md#network-member-and-bus-contracts).

### Errors

#### `Cyborg::Error`

Raised for `Cyborg`-specific misuse. Not currently raised by any code path in this gem's own methods — reserved for future use and for extensions built on top of `Cyborg`.

---

## `RobotLab::Cyborg::Channel`

The abstract base class for the *means* of reaching a human. Subclass and implement `#deliver`/`#receive` to bridge to a new transport — see [Building Custom Channels](custom_channels.md).

| Method | Signature | Description |
|---|---|---|
| `deliver` | `deliver(message) → ChannelMessage` | send a message out to the human (network → human). Must be implemented by subclasses. |
| `receive` | `receive(timeout: nil) → ChannelMessage, nil` | return the next message from the human, waiting up to `timeout` seconds; `nil` on timeout (transient — not "closed"). Must be implemented by subclasses. |
| `correlates?` | `→ Boolean` | whether inbound answers are tagged with the question they reply to. Default `false`. |
| `close` | `→ void` | release resources. Default no-op. |

### `Channel::Terminal`

`Terminal.new(input: $stdin, output: $stdout, name: "cyborg")` — the human at a keyboard; the default channel when none is injected. `deliver` prints `[sender] content`, followed by `> ` for questions. `receive(timeout:)` honors the timeout via `IO#wait_readable` on a real IO (a `StringIO` in tests responds immediately). `correlates?` is `false`.

### `Channel::Scripted`

`Scripted.new(answers = [])` — canned answers consumed in order; `correlates?` is `true`. `#asked` (`Array<String>`) records every question shown, in order — useful for asserting what the human saw in tests.

```ruby
scripted = RobotLab::Cyborg::Channel::Scripted.new(["yes", "ship it"])
bot = RobotLab::Cyborg.new(name: "dewayne", channel: scripted)
# ... run something that asks two questions ...
scripted.asked   # => ["first question text", "second question text"]
```

---

## `RobotLab::Cyborg::ChannelMessage`

```ruby
ChannelMessage = Data.define(:id, :content, :in_reply_to, :sender, :kind, :at)
```

Constructed as `ChannelMessage.new(content:, id: nil, in_reply_to: nil, sender: nil, kind: :message, at: nil)` — `at` defaults to `Time.now`. `#question?` returns `true` when `kind == :question`.

---

## `RobotLab::Cyborg::Interviewer`

The process that conducts a human interaction over an injected `Channel`. See [How It Works](how_it_works.md#asking-asynchronously) for the full asking/correlation/timeout model.

#### `new(channel:, default_timeout: nil)`

#### `ask(content, choices: nil, default: nil) → Question`

Delivers the question (immediately on a correlating channel, or queued behind a serialized one) and returns a pending `Question` without blocking.

#### `ask_and_wait(content, timeout: @default_timeout, **) → String, nil`

`ask(**).answer(timeout:)` — the synchronous form.

#### `on_initiative(&block) → self`

Registers the handler for inbound messages that answer no outstanding question.

#### `listen → self` / `unlisten → self`

Keep the consumer alive with nothing outstanding (or let it wind down again).

#### `close → void`

Stops the consumer and closes the channel.

#### `expire(question) → void`

Removes `question` from the outstanding set and advances a serialized queue. Called by `Question#answer` on timeout — not normally called directly.

#### `last_error → StandardError, nil`

The last error a handler or channel raised inside the consumer loop (caught, not re-raised, so the consumer keeps running).

---

## `RobotLab::Cyborg::Question`

A pending question handed to the human; a one-shot future for its answer.

| Reader | Type | Description |
|---|---|---|
| `id` | `Integer` | correlation id, unique within an `Interviewer` |
| `content` | `String` | the question text |
| `choices` | `Array<String>`, `nil` | multiple-choice options, if any |
| `default` | `String`, `nil` | value used on an empty answer or a timeout |

#### `answer(timeout: nil) → String, nil`

Blocks up to `timeout` seconds for the human's (already-interpreted) answer. On timeout, expires the question via its `Interviewer` and returns `default` (`nil` if none).

#### `resolve(answer) → void`

Delivers the answer — called by the `Interviewer`'s consumer, not normally called directly.

---

## `RobotLab::Cyborg::Conversation`

Turns a listening `Cyborg` into a multi-peer, `@mention`-addressed chat participant. See [How It Works](how_it_works.md#conversation-multi-peer-chat-by-mention).

#### `new(cyborg:, peers: [])`

#### `peers → Array<String>`

The addressable roster.

#### `add_peer(name) → self`

Adds an addressable peer.

#### `start → self`

Registers `on_human` routing and calls `cyborg.listen`. Idempotent.

#### `stop → self`

Calls `cyborg.unlisten`.

#### `route(line) → Array<String>`

Routes one line of human input by `@mention` (fan-out to every mentioned peer; no mention → broadcast to all known peers) and returns the names it was actually sent to. Unknown mentions are reported back to the human and excluded; a line with no resolvable recipient sends nothing.

---

## Related Core Classes (from `robot_lab`, not this gem)

Used throughout this gem's public API but defined in core `robot_lab` — see that gem's docs for full detail:

| Class | Relevance here |
|---|---|
| `RobotLab::RobotResult` | what `Cyborg#run`/`#call` return; `#reply` is the human's answer text |
| `RobotLab::DelegationFuture` | returned by `delegate(async: true)`; `DelegationFuture::DelegationTimeout` on a `value(timeout:)` expiry |
| `RobotLab::Robot::BusMessaging` | mixed into `Cyborg` for bus send/receive; see the caveat above about `on_message`/`respond_to_tasks`/`serve` |
| `RobotLab::Memory` | `remember`/`recall`'s backing store; `#current_writer=` is what `with_writer` toggles around a memory write |
| `RobotLab::RobotMessage` | the bus message type `assign`/`send_message` produce and `#inbox` holds |
