# How It Works

## The Means and the Process: Channel and Interviewer

Reaching the human is deliberately split into two small, separately-testable concerns:

- **`Channel`** is the *means* — a dumb, bidirectional pipe. It knows how to `deliver` a message **out** to the human and how to `receive` a message the human sends **in**. It has no concept of a "question" or an "answer" — just messages crossing a boundary.
- **`Interviewer`** is the *process* — it conducts the interaction over whatever channel is injected. It tracks which questions are outstanding, decides which inbound message answers which question, and surfaces everything else as unsolicited human *initiative*.

This split is why `$stdin`/`$stdout` live **only** inside `Channel::Terminal` — nothing else in the gem assumes a terminal. Swapping in a Slack, email, or web-form channel changes nothing about how `Interviewer`, `Cyborg`, or `Conversation` work. See [Building Custom Channels](custom_channels.md) to write one.

### `ChannelMessage`

The one data shape that crosses the boundary in both directions:

```ruby
ChannelMessage = Data.define(:id, :content, :in_reply_to, :sender, :kind, :at)
```

| Field | Meaning |
|---|---|
| `id` | the question id this message carries (outbound) or answers (inbound, when the channel can correlate) |
| `content` | the human-readable text |
| `in_reply_to` | set by the channel when it can tie an inbound answer to a specific question (a Slack thread, an email `In-Reply-To`) |
| `sender` | who the message is from/for, for display |
| `kind` | `:question` \| `:answer` \| `:message` \| `:notice` |
| `at` | `Time.now` unless given |

`kind == :question` (checked via the `question?` predicate) is what tells `Channel::Terminal` to print a `> ` prompt after the line; other kinds (inbound peer messages, notices) print without one, so unsolicited traffic doesn't spam the input cursor.

### Built-in Channels

**`Channel::Terminal`** — the human at a keyboard, and the default when no `channel:` is given.

- `input:`/`output:` are injectable (default `$stdin`/`$stdout`); inject `StringIO` in tests.
- `deliver` is synchronized with a `Mutex` so a question and an inbound peer message never interleave on screen.
- `receive(timeout:)` uses `IO.wait_readable` on a real IO so timeouts, shutdown, and question expiry all work; a non-selectable stream (a `StringIO` in tests) returns immediately from `#gets`, which is equally responsive.
- A `nil` line from `#gets` (EOF) is treated as "nothing arrived" and propagates as `nil`.
- `correlates?` is `false` — a bare terminal carries no correlation, so `in_reply_to` always stays `nil` on what it produces.

**`Channel::Scripted`** — canned answers for tests, automation, and replay.

- Constructed with an array (or single value) of answers, consumed in order.
- `correlates?` is `true` — each delivered question is paired with the *next* scripted answer **at delivery time** and stamped with that question's id, so correlation is exact and deterministic.
- Every question shown is recorded in `#asked`, so tests can assert on what the human saw: `cyborg.channel.asked`.
- When the script runs dry, a delivered question simply goes unanswered — modeling a human who never replies — and the `Interviewer`'s timeout (if any) takes over. Supply enough answers, or an `ask_timeout`, for any code path that asks more questions than you scripted.

## Asking Asynchronously

Asking is **always** asynchronous, whatever the channel — a human's answer may be the very next message, may arrive several messages later (after they say other things first), or may never come at all. So `Interviewer#ask` never blocks: it delivers the question and returns a `Question`, a one-shot future, immediately.

```ruby
question = interviewer.ask("Deploy now?")   # returns instantly
# ... do other things ...
answer = question.answer(timeout: 30)       # blocks here, not before
```

`Interviewer#ask_and_wait` (and `Cyborg#ask`) combine both steps into one call for the common synchronous case — this is the boundary a pipeline step or a bus task handler actually needs: block *this* thread, but don't block the channel's consumer thread.

`Cyborg#ask_async` exposes the non-blocking primitive directly, returning the pending `Question` so the caller decides when (and whether) to wait — the primitive a durable/suspendable human step would need to persist (see [Roadmap: Durable Human Steps](#roadmap-durable-human-steps)).

### The Background Consumer

`Interviewer` lazily starts a single background thread (`ensure_consumer`) the first time a question is outstanding, or when `#listen` is called. It polls `channel.receive(timeout: 0.05)` in a loop and, for each inbound message, either resolves the question it answers or calls the `on_initiative` handler.

The consumer is deliberately hard to kill:

- **A handler or channel error never wedges it.** Any `StandardError` raised while dispatching a message (in a channel read, in `on_initiative`, in interpreting an answer) is caught, recorded in `Interviewer#last_error`, and the loop keeps running. Before this, a throwing handler used to kill the consumer thread and hang every future `ask` — this was fixed as part of a design review (see `CHANGELOG.md`, item *A1*).
- **It stops itself once idle**, unless `#listen` has been called: no questions outstanding and not in always-on mode → the loop exits and `@running` resets, so the next `#ask` (or `#listen`) restarts it cleanly. Both the start and stop paths flip `@running` under the same mutex, so a restart can never race a shutdown.
- **`#close`** stops it for good and closes the channel — call this when a `Cyborg`/`Interviewer` is done and its channel resources (a socket, a file handle) need releasing.

### Correlation vs. Serialization

Whether more than one question can be outstanding at once depends entirely on the channel:

- A channel that **can** tie an inbound answer back to its question (`correlates? == true` — Slack threads, email `In-Reply-To`, `Channel::Scripted`) lets any number of questions be outstanding concurrently. Each is delivered immediately; `Interviewer#dispatch` resolves whichever one an inbound message's `in_reply_to` names.
- A channel that **cannot** (`correlates? == false` — a bare terminal) gets **serialized**: only one question is ever "on the wire" at a time (`@active_id`). Additional `ask` calls queue in `@pending` and are delivered one at a time as the active question resolves or expires (`pump_pending`/`release_active`). An inbound message with no `in_reply_to` resolves whichever question is currently active. This makes mis-attribution — a fast second answer accidentally resolving the first question — impossible.

An inbound message that names no outstanding question (an unknown/expired id, or an answer arriving when nothing is active) matches nothing and is routed to `on_initiative` instead — the human speaking as a peer, unprompted.

### Interpreting an Answer

Before resolving a `Question`, the `Interviewer` runs the raw text through `interpret`:

- An empty answer falls back to the question's `default`, when one was given.
- If the question had `choices:`, a bare number is mapped to the corresponding choice (1-indexed) — out-of-range numbers, and any non-numeric text, pass through unchanged as free text.
- The result is always coerced to a `String`, so a genuine empty answer (`""`) is never confused with a timeout (`nil`).

### Timeouts and Expiry

`Question#answer(timeout:)` blocks on an internal `Thread::Queue` (the mailbox `Interviewer#dispatch` pushes into). If nothing arrives within `timeout`:

1. The question calls back into `Interviewer#expire(self)`, which removes it from the outstanding set (so a later, unrelated answer can never claim it) and, on a serialized channel, advances the queue to the next pending question.
2. `#answer` returns the question's `default` (`nil` if none was given).

`nil` from `#answer` is therefore unambiguous: it means "no answer, no default" — never "the human answered with an empty string."

## Cyborg: The Human Peer

### Network Member and Bus Contracts

`Cyborg` satisfies the same two contracts a `Robot` does, so a network (or another peer) never has to know which one it's talking to:

- **The `SimpleFlow` step contract** — `#call(result)`. The network invokes this when a pipeline reaches the human's task; `Cyborg` extracts the incoming message and shared memory from the pipeline `Result` (`extract_run_context`), calls its own `#run`, and threads a `RobotResult` back into the pipeline the same way a robot's step would (`result.with_context(name, robot_result).continue(robot_result)`). Any exception is caught and turned into an error-shaped `RobotResult` rather than raising through the pipeline.
- **The `#run` contract** — `run(message = nil, network_memory: nil, memory: nil, **)`. This is what makes a `Cyborg` a valid `delegate`/`spawn` target anywhere a `Robot` is: it asks the human the given message (via `#ask`) and wraps the answer in a `RobotResult`, so `result.reply` works identically regardless of which kind of peer produced it.

`Cyborg` also **includes `RobotLab::Robot::BusMessaging` verbatim** — the same module `Robot` uses for `send_message`/`send_reply`/`on_message`/`spawn`/bus-poller wiring. This is why a robot and a human are wire-compatible peers on the same `TypedBus`: there is only one implementation of "how a member talks on the bus," shared by both.

**Caveat:** `Cyborg#initialize` wires its own inbound handler — `@message_handler = method(:handle_incoming)` — to get its default human-in-the-loop behavior (surface the task, ask, auto-reply). `BusMessaging#on_message`, `#respond_to_tasks`, and `#serve` all *replace* `@message_handler` wholesale. Calling any of them on a `Cyborg` overwrites `handle_incoming` and disables the built-in ask/auto-reply flow — those three methods are meant for `Robot`s opting *into* task-serving behavior a `Cyborg` already has by default. If you need custom bus-message handling on a `Cyborg`, build it around `#on_task`/`#on_human` instead (see below), not `#on_message`.

### The Inbound Task Lifecycle

`handle_incoming(message)` — the private method wired as `@message_handler` — is what runs on the bus poller's drain thread for every message addressed to this peer:

1. The message is recorded in `#inbox` (thread-safe, for later inspection).
2. If it's a **reply** to something this peer sent earlier, it's shown to the human via the channel (`kind: :message`) and handling stops there — replies don't get re-asked as tasks.
3. Otherwise it's a **fresh task**, handled by `respond_to_task`.

`respond_to_task` never blocks the poller:

- If the peer is `!available?` (offline), it declines immediately — a reply saying `"(name is unavailable)"` is sent back at once (if `auto_reply` and a bus are configured) rather than waiting on a human who won't answer.
- Otherwise, it spawns a **new thread** that asks the human (`ask(task_prompt(message))`), sends the answer back as a reply once it arrives (again, if `auto_reply` and a bus are configured, and only if there is an answer), and invokes the `#on_task` callback with the original message and the answer. Any error in that thread is caught and logged with `warn`, not raised — a slow or crashing human-answer thread can never take down the bus poller.

This is the fix for a real deadlock: before it, an inbound task ran synchronously on the poller thread, so a slow (or absent) human blocked delivery of every other message to every other peer sharing that poller group.

### Duplex: Talking Back to the Human

Two directions, both automatic in the common case:

- **Network → human**: any inbound bus message or reply is shown on the channel via `deliver_to_human`, best-effort (a channel error here is swallowed — a broken display must never break message intake). Call `Cyborg#tell(text, kind: :notice)` yourself to push an unprompted line (a status update, a warning) the same way.
- **Human → network**: an inbound channel message that answers no outstanding question is *initiative* — the human speaking unprompted. `Interviewer#on_initiative` routes it to `Cyborg#handle_human_initiative`, which in turn calls the `#on_human` callback you register. `Conversation` (below) is the built-in way to turn that initiative into addressed bus tasks; you can also register `#on_human` directly for custom routing.

### Always-On Listening

By default, the `Interviewer`'s consumer thread only runs while a question is outstanding — there's nothing to read otherwise. `Cyborg#listen` (and `Conversation#start`, which calls it) keeps the consumer alive with *no* question pending, so the human can address the network unprompted at any time; their input arrives via `#on_human`. `#unlisten` (and `Conversation#stop`) turn this back off; the consumer then winds down once nothing is outstanding, same as normal.

### Presence and Availability

```ruby
cyborg.online!      # taking work now (default)
cyborg.away!         # present but slow — still asked, use a generous timeout
cyborg.offline!      # not taking work — inbound tasks declined immediately
cyborg.available?    # => false only when :offline
```

Presence is plain in-memory state (`@presence`, guarded by a mutex) — it doesn't itself change *how* a question is asked, only what `respond_to_task` does with an inbound bus task before asking at all. A network or dispatcher can check `available?` before routing work to a specific human, to pick another peer or escalate instead of tasking someone who will just decline (or, if `:away`, take a long time).

### Typed and Validated Answers

```ruby
cyborg.ask("Deploy?")                                    # raw text (or the default)
cyborg.ask_int("How many replicas?")                      # re-asks until a parseable Integer
cyborg.ask_confirm("Proceed?")                            # => true / false / nil
cyborg.ask("Pick one", choices: %w[a b c])                # numbered choices; a bare digit maps to one
cyborg.ask("Env?", validate: ->(a) { %w[dev prod].include?(a) ? a : nil }, retries: 2)
```

`#ask`'s `validate:` contract: return the (optionally coerced) value when the answer is acceptable, or `nil` to reject it. On rejection, `Cyborg` tells the human why (`"Sorry, I couldn't use ..."`) and re-asks, up to `retries` extra attempts, after which it falls back to `default`. `ask_int`/`ask_confirm` are just `ask` with a pre-built `validate:`.

### Delegation

```ruby
result = cyborg.delegate(to: some_robot_or_cyborg, task: "Summarize this")     # blocks, returns RobotResult
future = cyborg.delegate(to: some_robot_or_cyborg, task: "Summarize this", async: true)  # returns a DelegationFuture
future.value            # blocks here instead; raises DelegationFuture::DelegationTimeout if value(timeout:) expires
```

`delegate` works against **any** target that responds to `#run` — a `Robot` or another `Cyborg` — because both satisfy the same `#run` contract. The synchronous form calls `to.run(task, **)` directly and stamps `delegated_by` on the result. The async form spawns a `Thread`, resolves or rejects a `RobotLab::DelegationFuture` from it, and returns the future immediately — so a human (or a robot) can fan a task out to several peers in parallel and collect results later.

`assign(to:, task:)` is the fire-and-forget bus counterpart — an alias for `BusMessaging#send_message`, named for how a human hands off work; correlate its reply later via `cyborg.outbox[message.key]`.

### Shared Memory

```ruby
cyborg.remember(:decision, "ship it")       # writes to the active memory
cyborg.recall(:sentiment, wait: 30)         # reads from it, optionally blocking for up to 30s
cyborg.attach_memory(some_network_memory)   # explicit target (a network run does this for you)
cyborg.detach_memory                        # back to this peer's own standalone memory
```

"The active memory" is the network's shared memory while attached, and this peer's own standalone `memory:` otherwise (`current_memory`, mutex-guarded). `#run` calls `attach_memory` automatically whenever a `network_memory:` is passed in — which is how a network run wires it up without you doing so by hand. Detaching explicitly matters when a peer might otherwise keep writing to a finished network's memory after that run has ended.

`remember`/`recall` additionally set/restore the memory's `current_writer` around the call (`with_writer`, a no-op for memory implementations that don't track one) — a no-op for memories that don't track a writer, and otherwise how downstream consumers know a given memory write came from this human rather than a robot.

## Conversation: Multi-Peer Chat by @mention

`Conversation` turns a listening `Cyborg` into an interactive participant among several named peers:

```ruby
you  = RobotLab::Cyborg.new(name: "you", bus: bus)
chat = you.converse(peers: %w[analyst scribe])
# human types: "hey @analyst and @scribe: status?"  -> both are tasked
# human types: "status?"                             -> broadcasts to both (no mention = everyone)
```

`Cyborg#converse(peers:)` is sugar for `Conversation.new(cyborg: self, peers: peers).start`. `#start` registers an `#on_human` handler that routes each unprompted line and calls `#listen`; `#stop` calls `#unlisten`.

Routing rules (`Conversation#route`):

- Every `@name` mention in the line (via the `MENTION = /@(\w+)/` pattern, in order of first appearance, deduplicated) addresses that peer.
- A line with **no** mention broadcasts to **every** known peer.
- A line whose mentions are *all* unknown peers is **not sent** — `Conversation` tells the human which name(s) weren't recognized, and (if there were no other, valid mentions) which peers *are* known.
- A line mixing known and unknown mentions still sends to the known ones, after reporting the unknown ones.

Replies come back automatically — `Cyborg`'s duplex delivers inbound bus traffic to the channel regardless of how the outbound task was sent, so `Conversation` only has to handle the human → network direction; it never polls for or renders replies itself.

`add_peer(name)` grows the addressable roster after construction (e.g. as new robots join a running session).

## Roadmap: Durable Human Steps

A human step currently holds a thread while it waits (`ask`/`ask_and_wait` block; the underlying `Question#answer` sits on a blocking `Thread::Queue#pop`). `ask_async` returns the pending `Question` without blocking — the primitive a durable integration would need to persist across a process restart. The intended path, per the gem's `CHANGELOG.md` and `README.md`, is to store a pending decision through **`robot_lab-durable`** (and `robot_lab-to`'s `DecisionManager`) so a human decision survives a restart without pinning a thread for the duration. Per-peer cryptographic identity/attribution (signed events), building on the existing per-message `sender`/`from`, is a complementary but separate direction. Neither is implemented in this gem as of this writing — treat this section as intent, not a shipped feature.
