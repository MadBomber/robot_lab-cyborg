# Building Custom Channels

`Channel::Terminal` and `Channel::Scripted` are the only channels this gem ships, but the whole point of the `Channel` abstraction is that a Slack, email, SMS, or web-form transport is *just another subclass* — nothing in `Cyborg`, `Interviewer`, or `Conversation` assumes a terminal. This page covers what a custom channel needs to get right.

## The Contract

Subclass `RobotLab::Cyborg::Channel` and implement two methods:

```ruby
class MyChannel < RobotLab::Cyborg::Channel
  def deliver(message)   # ChannelMessage -> ChannelMessage
    # send `message.content` out to the human, over whatever transport this is.
    # Return the message (or a copy of it) once sent.
  end

  def receive(timeout: nil)   # -> ChannelMessage, nil
    # Wait up to `timeout` seconds for the human's next message.
    # Return nil if nothing arrives in that window — nil means "not yet",
    # not "closed"; the Interviewer will call #receive again.
  end
end
```

Override two more only if they apply:

```ruby
def correlates? = true   # default: false — see "Correlation" below
def close                # default: no-op — release sockets, files, etc. here
end
```

## `#receive` Must Honor `timeout:`

This is the one requirement that's easy to get wrong. The `Interviewer`'s background consumer calls `channel.receive(timeout: 0.05)` in a tight loop (`Interviewer::POLL_INTERVAL`), and relies on that call actually returning within roughly that window — every 50ms — so it can notice `Question` timeouts, respond to `#close`, and stay responsive. A `#receive` that blocks indefinitely regardless of `timeout:` will make questions never expire and `#close` hang.

For a polling-style transport (an HTTP API you poll, a database table), implement this literally: poll, and if nothing new has arrived within `timeout` seconds, return `nil`. For a push-style transport (a webhook, a queue with blocking pop), buffer inbound messages into a `Thread::Queue` from your webhook handler and let `receive` do `@inbox.pop(timeout: timeout)` — exactly what `Channel::Scripted` and the `Autobot` example below do.

## Correlation

Whether `correlates?` should be `true` or `false` depends on whether your transport can tie an inbound answer back to the specific question it answers:

- **Slack threads** — reply in the same thread as the question; the thread's parent message id becomes `in_reply_to`. `correlates? = true`.
- **Email** — the `In-Reply-To` header names the message id being answered. `correlates? = true`.
- **A bare terminal, or an SMS number with no threading** — there's no way to tell which question an inbound text answers except "whichever one is outstanding." `correlates? = false` — the `Interviewer` will serialize (one question on the wire at a time) so an answer is never mis-attributed. See [How It Works — Correlation vs. Serialization](how_it_works.md#correlation-vs-serialization).

Get this wrong in the `true` direction (claiming correlation your transport doesn't actually have) and answers can resolve the wrong question when more than one is outstanding. Getting it wrong in the `false` direction just costs you unnecessary serialization — safe, but limits concurrent questions on a channel that could actually support them.

## A Worked Example: an Automated Peer

Every peer on the bus — human or otherwise — is reached through a `Channel`, which means a scripted or programmatic "human" is just a `Channel` whose deliver/receive are backed by a block instead of a person. This is exactly how `examples/02_terminal_mentions.rb` builds key-free canned peers that still go through the real `Cyborg`/`Interviewer` machinery:

```ruby
class Autobot < RobotLab::Cyborg::Channel
  def initialize(&reply)
    @reply = reply
    @inbox = Thread::Queue.new
    super()
  end

  def correlates? = true
  def deliver(message) = message.question? ? @inbox.push(reply_to(message)) : message
  def receive(timeout: nil) = timeout ? @inbox.pop(timeout: timeout) : @inbox.pop
  def close = @inbox.close

  private

  def reply_to(message)
    RobotLab::Cyborg::ChannelMessage.new(content: @reply.call(message.content), in_reply_to: message.id, kind: :answer)
  end
end

analyst = RobotLab::Cyborg.new(name: "analyst", bus: bus,
                                channel: Autobot.new { |_question| "error rate is 0.2% over the last hour." })
```

Notice what `Autobot` does *not* need to know about: bus wiring, reply correlation logic beyond stamping `in_reply_to`, or anything about questions vs. answers as concepts — that's the `Interviewer`'s job. It only has to answer "how do I move a `ChannelMessage` across this boundary."

## Sketch: a Slack Channel

A real Slack channel is push-style (events arrive via the Events API or Socket Mode) and does correlate (thread replies):

```ruby
class SlackChannel < RobotLab::Cyborg::Channel
  def initialize(slack_client:, channel_id:)
    @slack   = slack_client
    @channel_id = channel_id
    @inbox   = Thread::Queue.new
    super()
  end

  def correlates? = true

  def deliver(message)
    response = @slack.chat_postMessage(channel: @channel_id, text: message.content,
                                        thread_ts: message.in_reply_to)
    message   # or a copy carrying response["ts"] if you need the posted id later
  end

  def receive(timeout: nil)
    timeout ? @inbox.pop(timeout: timeout) : @inbox.pop
  end

  def close
    @inbox.close
  end

  # Called from your Slack event handler / webhook controller, on whatever
  # thread that framework hands events to you on:
  def handle_slack_event(event)
    @inbox.push(RobotLab::Cyborg::ChannelMessage.new(
      content: event["text"],
      in_reply_to: event["thread_ts"],   # nil for a top-level message
      sender: event["user"]
    ))
  end
end
```

The pattern generalizes directly to email (`In-Reply-To`/`Message-Id` headers instead of Slack thread timestamps), a web form (poll a table of submitted answers, or push from a controller action the same way), or an SMS/queue transport.

## Testing a Custom Channel

Give it the same treatment `test/robot_lab/test_interviewer.rb`'s `Probe` channel gets: a hand-driven channel whose `receive` you control from the test, so you can push messages (correlated or not) in whatever order you want and assert on what the `Interviewer`/`Cyborg` did with them, without depending on real network/IO timing.
