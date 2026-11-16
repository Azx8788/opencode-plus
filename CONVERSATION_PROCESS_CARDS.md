# Conversation process cards

## User decision

- Borrow the conversation structure from RikkaHub, not its background or theme.
- Keep assistant prose separate from thoughts and operations.
- Group consecutive process steps in one collapsible card; even a single
  thought or tool call belongs in a card.
- Put elapsed time, model steps, speed and context usage under each reply.
- Preserve the model/variant and the in-progress named-key switch feature.

## Reference, not vendored source

Reference: [rikkahub/rikkahub](https://github.com/rikkahub/rikkahub), inspected at
`a75f3f9cd7863bf571642044112e9bf443263f73`.

Relevant Kotlin files were downloaded, with the project's AGPL-3.0 license,
to `/tmp/opencode/rikkahub-reference` for local study:

- `ChatMessageCot.kt`: content versus consecutive process blocks.
- `ChatMessage.kt`, `ChatMessageReasoning.kt`, `ChatMessageTools.kt`: the
  collapsible process container and its steps.
- `ChatMessageNerdLine.kt`: final-request context versus cumulative usage.

No Kotlin code, assets or other RikkaHub source are included in this project.
The Flutter implementation uses OpenCode Plus's own kit and theme roles.

## Rendering and state

`transcript_turns.dart` keeps content/process boundaries identical while
streaming and after completion. Prose is not folded, and process is not moved
across intervening prose. Interactive answer cards, permission requests and
important error notices retain their own presentation.

`KitWorkLine` now draws a themed surface around its existing bounded timeline.
The active group opens to its newest three steps. Completed groups default to
collapsed, unless manually opened, configured to show reasoning, failed, or
holding a produced file. Manual state is namespaced by message and part IDs;
V2's repeated `reasoning-0` IDs do not affect other replies. Output previews
remain bounded, and earlier steps/full output are revealed on demand.

## Measurement definitions

- **Steps:** distinct assistant model messages in the reply; shell notices
  are not model calls, and replayed IDs are counted once.
- **Elapsed time:** the server-recorded first model start to final model
  completion, including its tool work. It is not the phone's receive time.
- **Speed:** output plus reasoning tokens divided by recorded provider
  streaming time (`firstToken` to `streamed`). Explicit complete V1 text/thought
  intervals can supply the same measurement; overlaps are counted once.
  Tool waits and gaps between model steps are not streaming time.
- **Context:** the final model request's normalized token total, not the sum
  of all requests. Cache hits are that request's `cacheRead`.
- **Totals:** all usage actually reported in the reply, inspectable separately.
- **Unknown:** incomplete/missing timing, invalid intervals or missing final
  usage do not become estimates, zeros in the context row, or an earlier
  request's context. Missing speed is left out; Details explains missing data.

The V2 message and event adapters preserve the server's streaming/reasoning
timestamps and retain usage through step completion. Statistics are shown
once per reply, including history, independent of timestamp preferences.

## Verification

`test/conversation_process_cards_test.dart` covers the real rendering path,
card boundaries, prose order, single-step/failed/running cards, persistent
expansion, statistics details and a single footer, bounded output, and 320 dp
at 200% text in light/dark themes.

`test/turn_statistics_test.dart` covers measurement definitions, missing data,
overlap/replay protection, V2 refetch mapping and live-event timestamp parity.
The full Flutter/native/APK CI remains the release gate. Phone acceptance
still needs an installed build; CI is not a substitute for that result.
