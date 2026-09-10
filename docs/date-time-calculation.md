# Local date and time calculation

The `dateTimeProvider` in `apps/desktop/src/providers/datetime.ts` performs explicit
calendar arithmetic and time-zone conversions on the device using `Date` and
`Intl.DateTimeFormat`. It adds no dependencies, network requests, paid calls, or
native IPC. Its provider ID is `datetime`; the copy action is
`dateTimeActionIds.copyResult` (`copy-datetime-result`).

## Input and result contract

| Input | Exact result |
| --- | --- |
| `2026-09-06 + 3 days` | `2026-09-09` |
| `2026-09-06 - 7 days` | `2026-08-30` |
| `2026년 9월 6일에서 3일 전` | `2026-09-03` |
| `2026-09-06 3일 후` | `2026-09-09` |
| `2026-09-09 - 2026-09-06` | `3 days` |
| `2026-09-06 to 2026-09-09` | `3 days` |
| `2026-09-06부터 2026-09-09까지` | `3 days` |
| `2026년 9월 6일과 2026년 9월 9일 차이` | `3 days` |
| `2026-09-06 09:00 Asia/Seoul to UTC` | `2026-09-06T00:00:00Z` |
| `2026년 9월 6일 09:00 서울에서 UTC로` | `2026-09-06T00:00:00Z` |
| `2026-09-06T00:00Z to Asia/Seoul` | `2026-09-06T09:00:00+09:00[Asia/Seoul]` |
| `2026-09-06 09:00 Asia/Seoul to America/New_York` | `2026-09-05T20:00:00-04:00[America/New_York]` |

Date arithmetic accepts whole days only, with `day`, `days`, or `일`. Korean
relative forms accept `후`, `뒤`, and `전`, optionally preceded by `에서`.
Gregorian calendar dates are explicit ISO `YYYY-MM-DD` or Korean
`YYYY년 M월 D일`; no machine locale, current date, or system time zone is inferred.
Calendar-day differences exclude the start day. Subtraction is left date minus
right date; intervals (`to`, `부터`, `~`, `→`, or Korean `와`/`과 … 차이`)
are end date minus start date, and reversing the dates produces a negative result.

Time-zone input requires an explicit date, 24-hour `HH:mm` (optional `:ss`),
and a source zone or UTC offset. Source and target use `to`, `in`, `->`, or `→`;
Korean `source에서 target로`/`target으로` is also accepted. `UTC`/`Z` and
IANA paths supported by the device are accepted; `서울` and `한국` map to
`Asia/Seoul`. Ambiguous abbreviations such as `CST`, city names, and bare clock
times are rejected rather than interpreted using the machine's location.

Results preserve seconds. UTC output ends in `Z`; other outputs include the exact
offset and resolved IANA zone in brackets. Date differences include `days` in
their stable copy value. The provider uses the current `calculation` answer shape,
sets `matchedQuery` to the trimmed input, and puts the exact displayed result in
`data.result`. It caches no results, returns no items for unrelated/incomplete
input or cancellation, and throws explanatory provider errors for recognized
invalid operations. No new shared answer type is required.

## Invalid input and time-zone transitions

Input is bounded to 256 characters, rejects control characters, and supports
calendar years 0001–9999. The maximum day operand is 3,652,058; results outside
the calendar-year range fail. Every date is validated by its Gregorian components,
including century leap rules. Invalid months/days, hours above 23, minutes or
seconds above 59, and invalid offsets fail. Leap seconds, fractions of days,
months/years, relative dates like `today`, and locale-dependent numeric dates
are not supported.

Without an explicit offset, IANA local times are supported from 1973 onwards.
For these modern dates, the resolver checks every whole-minute UTC offset from
−24 to +24 hours and round-trips each candidate through the device's time-zone
rules. It requires exactly one matching instant. This bounded search avoids
assuming a one-hour DST shift, sampling only today's offset, or silently selecting
the first matching time. Historical source dates before 1973 require an exact
UTC time or explicit offset because historical local-mean-time offsets can contain
seconds. Exact UTC inputs can still convert to historical target zones, including
second-bearing historical offsets.

The distinction between repeated local times, nonexistent local times, and exact
offset inputs follows the [TC39 time-zone ambiguity documentation](https://tc39.es/proposal-temporal/docs/timezone.html).
This implementation uses existing `Intl`; it does not depend on Temporal support.

- `2026-11-01 01:30 America/New_York to UTC` explains that the time occurs twice.
  `2026-11-01T01:30-04:00 America/New_York to UTC` gives `2026-11-01T05:30:00Z`,
  while `-05:00` gives `2026-11-01T06:30:00Z`.
- `2026-03-08 02:30 America/New_York to UTC` explains that the time does not exist.
  Supplying an offset alongside that nonexistent New York time also fails because
  the source time and zone do not round-trip.
- Half-hour transitions in `Australia/Lord_Howe` and the skipped date
  `2011-12-30` in `Pacific/Apia` are tested.

The device's installed time-zone data is authoritative for this local feature;
future rule changes require updated device/browser data. No live rules are fetched.

## Integration and validation

The coordinator owns provider registration, copy-action dispatch, and shared
localization. Register `dateTimeProvider` beside the existing instant-answer
providers and route `dateTimeActionIds.copyResult` to the existing clipboard
handler reading `item.data.result`. The new file uses `t(...)` for labels, context,
and errors so shared translations can be added without provider changes. Preserve
the stable exact result string when translating surrounding copy.

Validation command: `pnpm --filter @prism/desktop test src/providers/datetime.test.ts`.
The tests cover the quality-gate examples, Korean input, signed differences,
leap years and year bounds, UTC/day rollover, fractional-hour zones, DST gaps and
folds, explicit-offset agreement, full-date skips, invalid input, cancellation,
query correlation, and exact copy data. Provider tests and TypeScript validation
do not prove mounted UI registration, native WebView behavior, or clipboard
execution; those remain coordinator integration checks. No development server or
native app was started, restarted, or stopped.
