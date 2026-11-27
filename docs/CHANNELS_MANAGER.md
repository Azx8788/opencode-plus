# The manager agent and the task ledger

The channel layer used to be a relay: a prompt went to the OpenCode session, the
engine watched the server's events, and whatever the assistant said last was
copied into the chat. That design decided *when the agent was done* by reading a
mutable flag twice, 350 ms and 500 ms after `session.idle`, and it had no way to
express "the agent finished but the person was never told".

This document describes what replaced it, what it can do, and — the part that
matters when reading the code — what it deliberately cannot.

## Two layers

```
user → provider → engine → manager agent → submit_task → executor (OpenCode session)
                     ↑                                          │
                     └──── task finished (result, status) ──────┘
                     ↓
                 send_message → outbox → provider → user
```

* **Manager agent** — a model of its own, configured separately from the
  executor's. It reads the message, decides whether to submit work, and decides
  how to present the completed result. App commands and operational notices are
  handled directly by the engine.
* **Executor** — the existing OpenCode session. It never learns that the person
  is on QQ or Telegram, and its own text is never relayed on its own.

The manager is off by default and is currently wired to the two QQ channels.
Telegram uses the direct relay but shares the same task ledger and outbox.
With the manager off, its channels behave as they did
before: the engine relays the executor's last message. With it on but
unreachable, the same relay is used as a fallback, so a misconfigured manager is
a degradation, not an outage.

## The task ledger

`lib/channels/channel_tasks.dart` records every submitted task:

| Field | Meaning |
| --- | --- |
| `id` | Unique turn ID, also recorded in the outbox |
| `conversationKey`, `providerId`, `accountId`, `conversationId`, `userId` | who and where |
| `sessionId` | the OpenCode session it ran in |
| `status` | `created → submitted → running → waitingPermission → completed / failed / cancelled` |
| `delivery` | `pending → delivering → delivered / deferred / failed / unknown` |
| `result`, `error` | what the agent said, what it reported |
| `answeredButUndelivered` | the case the old model could not express |

Status and delivery move independently. A task can be `completed` with delivery
`failed` — the agent worked, the platform refused the message — and the manager
page shows exactly that as "未送达". A forwarding receipt or progress notice
is not a final delivery receipt.

Transitions are checked in one table (`ChannelTaskMachine`). A `session.idle`
that arrives after `/stop` cannot resurrect a cancelled task.

## Tools the manager has

| Tool | Effect | Limits |
| --- | --- | --- |
| `submit_task` | submits text to the executor, returns the task id | no workspace, model or agent choice — the app's own settings decide |
| `send_message` | the only way anything reaches the chat | no recipient parameter: the conversation is fixed when the host is built |
| `get_task_status` | reads the ledger | this conversation and sender only |
| `get_task_result` | reads the result text | empty until the task completes |
| `cancel_task` | aborts the session and marks the task cancelled | see the `/stop` note below |
| `list_tasks` | recent tasks of this conversation | bounded window |
| `stay_silent` | records a deliberate decision not to answer | the engine does not fill the silence |

The model cannot approve a permission, cannot create a session, cannot send a
file, and cannot address another chat. Those are the same boundaries the channel
layer already had; the manager does not widen them.

## Message classification

* A plain message during a running task is submitted again to the same session:
  the executor sees it as a follow-up, and the engine counts it as a supplement
  of the same task ("已并入当前任务").
* `/queue` keeps the text locally and starts it as a new task after the current
  one ends ("已加入队列").
* `/stop` clears the local queue and asks the server to stop the bound session.
  A turn marked cancelled cannot be completed by a late event.
* A permission request pauses the task (`waitingPermission`) and is reported in
  the chat; only the app can answer it.

## The race that used to lose answers

`sender` fired an "update" 350 ms after a message completed and a "final answer"
500 ms after the session went idle. Both read `runtime.running`: the update
returned when it was false, the final returned when it was true. A queued prompt
starting the next turn in between satisfied both, and the answer was dropped.

A probe bracketed the hole:

| Next turn starts | Before | After |
| --- | --- | --- |
| 10 ms after idle | sent as an update | final answer, once |
| 200 ms | sent as an update | final answer, once |
| 400 ms | **lost** | final answer, once |
| 480 ms | **lost** | final answer, once |
| 700 ms | final answer | final answer, once |

The fix is not a longer delay. A turn (`lib/channels/channel_turn.dart`) now
carries its own id, session, delivered message ids and outcome; a late callback
reads the turn it was scheduled for. Delivery is decided by message id, and an
update is only sent when a tool start proves the message before it was
intermediate. `test/channels/channel_turn_test.dart` runs all seven timings.

## Known limits, stated rather than hidden

1. **`/stop` and the server inbox.** `/stop` aborts the session and clears the
   local queue. A prompt already admitted to the OpenCode server's per-session
   inbox may still be delivered when the current turn ends. The app does not
   pretend otherwise: the task is marked cancelled, and nothing from it is
   delivered, but the executor may still run the queued text. **NOT VERIFIED**
   against a real server: whether `abort` clears the inbox is a server
   behaviour, and this build has no way to inspect it.
2. **Official QQ's five-minute window.** A passive reply must answer a specific
   `msg_id` within five minutes, at most five times. A task that runs longer
   cannot deliver its answer at all unless the bot has the `activeMessage`
   extension, which requires an application in the console. The channel reports
   "窗口已过期，本条消息未发送" instead of silently dropping it.
3. **Result attribution and recovery.** The relay uses the original session
   and looks up the assistant message by ID when the event supplies it.
   Without a message ID or a matching durable transcript, a bare idle event
   cannot identify the exact turn. Telegram can recover a positively matched
   result after a connection drop while the app is still running, but not
   resurrect an in-flight turn after process death.
4. **The manager's own memory is in-process.** Conversation history is a bounded
   list in memory; a restart loses the small talk, not the tasks.
5. **Model calls are bounded.** No streaming. A request retries once on a
   transient transport failure, HTTP 429 or HTTP 5xx, not after a timeout or
   auth error. If the manager produces no usable output, the relay is the
   fallback; a send with an unknown acknowledgement is not duplicated.

## Tests

| Suite | What it pins |
| --- | --- |
| `channel_turn_test.dart` | seven timings, at-most-once delivery, update vs final, cancellation, receipts, multi-conversation status |
| `channel_tasks_test.dart` | the state machine, persistence across a restart, refusals, engine recording, undelivered-but-answered |
| `manager_agent_test.dart` | the wire format, a 401, `send_message`, `submit_task`, an answer without `send_message`, `stay_silent`, the engine with a manager, the fallback when it cannot be reached |

The manager's tests use a loopback HTTP server. No real key, no real account,
and no test in CI talks to a model provider.
