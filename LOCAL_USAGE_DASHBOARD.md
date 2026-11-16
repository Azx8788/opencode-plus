# Local usage dashboard

Replaces Usage's spending section, not subscription limits. The existing cost,
budget, provider/model filtering and tool-reliability report remains in
“Exact usage, costs and budgets”. Fonts, app text size, theme packs, surface
styles and backgrounds continue through AppTheme / KitText / KitEffects.

## Design reference

RikkaHub `a75f3f9cd7863bf571642044112e9bf443263f73`:
`StatsPage.kt`, `StatsVM.kt`, `UsageRecordDAO.kt` and `UsageRecorder.kt`.
Downloaded for local study under `/tmp/opencode/rikkahub-reference`, with its
AGPL-3.0 license. No reference source, assets or SQL are vendored. The
dashboard is independently implemented in Flutter using Plus's existing kit.

## Honest data and scope

- The OpenCode V2 session-statistics endpoint supplies recorded sessions,
  prompts, model steps, activity dates, token categories, models and costs.
- It does **not** supply total message count or usage grouped by request
  source. The overview says “model requests”, not “messages”; source shares
  are explicitly unavailable, never inferred from token categories.
- Input = input + cache read + cache write; output = output + reasoning.
  Cache-hit tokens are a subset of input, not added to totals twice.
  Cache hit rate = cache read / input; no input means an unknown rate.
- App launches are main-app cold starts counted in preferences from the
  first successful write of this feature. Resumes, widgets, rebuilds and
  fictional pre-update launch history do not count. They are device-wide,
  not scoped to a server/project, and the starting date is shown.
- Totals and date labels use the response's actual covered interval. Model
  ranking identity includes provider and variant; overflow is “Other”.

## Time-series retrieval

The API's activity array counts model steps, not daily tokens. Activity is
drawn as an independent 53-week, Monday-first heatmap from a lifetime read.
Missing dates outside the response interval/future dates are dimmed, not zero.
Daily activity also has an accessible date-list view.

Token bars use the **same supported statistics endpoint** with explicit
half-open date bounds, timezone and project filter. No direct database access,
shell script, paid model request or provider-specific credential is involved.

- 7 and 30 days: one aggregate per local calendar day.
- 90 days: 30 three-day aggregates, clearly disclosed above the chart.
- All time: calendar months; long histories group multiple months so no
  selection needs more than 30 aggregates.
- At most two trend reads are in flight across superseded selections.
  Responses and cache entries cannot cross locations, timezones or projects.
- Range switching reuses up to 96 in-memory bucket responses. Pull to refresh
  clears that cache and refreshes the lifetime summary. Nothing polls.
- A failed or narrowed response is an unknown gap, **not** a zero bar. Retry
  refetches missing buckets; a bar/date list exposes its actual period.

## Verification

- `test/usage_dashboard_test.dart`: calendar bounds, month/day grouping,
  cache arithmetic, ranking identity, exact total preservation, unknown gaps.
- `test/usage_overview_dashboard_test.dart`: bounded concurrency, range cache,
  explicit refresh, project/location isolation, stale reads, failure/retry,
  launch semantics and corrupt optional metadata.
- `test/usage_dashboard_widget_test.dart`: range and chart interactions,
  date details, honest missing-data/empty states, five app styles, app text
  size, narrow layout, and screenshots rendered with shipped app fonts.

CI captures are artifacts named `usage-layout-<commit>`. They are widget
renderings, not proof of installed-device acceptance. Publishing remains
gated on all Flutter, Android native and APK jobs passing.
