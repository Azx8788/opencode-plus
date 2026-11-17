# Tasks, live measurements and search providers

## Identity contract

A user task is not a message turn. Independent user requests create a root;
steering an identified running execution retains its root. Explicit queued
requests create a separate root. When execution context or intent conflicts,
the association remains pending and is excluded from user-task counts.

The application adds `mobile.task` admission metadata. Subagent input is not
counted as user input. A child is linked to the originating model step only
when the tool result reports an exact child session ID; session `parentID`
alone cannot identify which request created it. Child failure does not alter
the parent's recorded outcome. Model steps and scheduled retries are separate;
a scheduled retry is not proof that another physical request was dispatched.

## Collection and coverage

The app-owned `mobile-insights` V2 plugin uses the official plugin SDK, durable
storage and public RPC. It retains event identity, task identity, timestamps,
model identity, token usage and structured error type/status. It does not
retain prompts, attachments, tool inputs/results, credentials or HTTP headers.

The server projection and device cache are bounded to 10,000 events. Truncation,
missing origins and missing usage are explicit. Older conversations without
task metadata cannot be divided into user tasks by timestamps alone.

Durable phase times decorate REST transcript reads so refetching does not
discard recorded text boundaries. Live display advances a server-clock anchor
using monotonic elapsed time; final values use recorded completion events.
Speed requires reported token usage and matching generation intervals. A
provider that reports usage only at completion cannot supply exact live TPS.
Text chunks are never counted as tokens. Hidden reasoning or generated tool
arguments must not be omitted from a speed denominator.

## UI contract

Chat and Usage open the same task-first tree/Gantt component. Expanding,
filtering, zooming and panning change presentation, not execution records.
Green/red/blue/yellow distinguish success/failure/running/queued. Cancelled,
interrupted and unknown are separate states. Only explicit HTTP 429 is labelled
provider refusal; slow responses do not prove rate limiting or concurrency.

Chat process cards retain their latest two steps and a reasoning entry when
earlier work is collapsed. Reasoning-body expansion is separate. Permission
waiting does not remove a thought. Live statistics do not depend on the
finished-turn Copy/More controls. Existing fonts and appearance settings remain
in effect. Quick-reply suggestions are not part of this work.

## Search providers

Settings → Agent → Search provider configures the connected OpenCode runtime.
The built-in provider catalogue and its integration credentials are reused;
there is no extra CLI/MCP installation and no credential copied into a plugin
or prompt. A provider must have an active credential before selection. Fixed
selection does not switch providers on failure. The Test action makes a real
search through the selected provider, not a language-model health probe.

The managed in-app runtime installs the plugin before its next server start.
An explicit installation action does not restart an active server. External
servers need the same plugin installed by their owner; the app does not write
into an unowned remote runtime.

## Verification

- `test/task_trace_test.dart`: task/message/request separation, pending origins,
  exact child association, parent/child outcomes and replay deduplication.
- `test/insights_plugin_test.dart`: executes generated Node code, verifies
  bounds/privacy, active-credential checks and fixed provider selection.
- `test/task_timeline_widget_test.dart`: real tree-expansion, zoom and detail
  clicks; counts cannot change when manipulating the chart.
- `test/conversation_process_cards_test.dart`: actual chat components, retained
  reasoning/tool entries, live statistics and appearance regression.

The plugin has also been qualified against an isolated OpenCode 2.1.1 runtime:
RPC activation, provider discovery and non-generating prompt-admission event
persistence. This is not a successful authenticated Tavily search. The latter
requires a Tavily credential authorized by the person in the application.
