# Currency conversion

Implemented on 2026-09-06 as the first M2-E conversion slice. Intraday market quotes remain out of scope.

## Everyday use

| Input | Result |
| --- | --- |
| `100 USD to KRW`, `100달러`, `$100` | Convert USD to KRW |
| `10000엔 원화` | Convert JPY to KRW |
| `1000원 달러`, `1000 KRW to USD` | Convert KRW to USD |
| `USD/KRW`, `유로 환율` | Show one unit in the target currency |
| `환율`, `exchange rates` | Show USD, EUR, 100 JPY, and CNY in KRW |

The selected result's Enter action copies the displayed numeric amount without grouping separators.
Calculator expressions and currency conversions use a dedicated instant-answer layout with a large
result, a separate input/expression, and the existing copy action. Currency results additionally show
the conversion direction, one-unit rate, date, and source. The four-rate overview uses two columns at
the default desktop width; each result retains its own listbox selection and copy action.
Amounts are rounded to the destination currency's standard minor units. This is a reference conversion,
not a bank buy/sell quote or an executable trade. Identical source and target currencies need no request.
Bare foreign currencies default to KRW; bare KRW defaults to USD. Supported codes are AUD, BRL, CAD,
CHF, CNY, CZK, DKK, EUR, GBP, HKD, HUF, IDR, ILS, INR, ISK, JPY, KRW, MXN, MYR, NOK, NZD, PHP,
PLN, RON, SEK, SGD, THB, TRY, USD, and ZAR. A missing source rate produces a failure, never an estimate.
Amounts allow correctly grouped commas, signs, up to six fractional digits, and absolute values up to 10^12.
Ambiguous `¥`, cryptocurrencies, arbitrary prose, and Korean number multipliers are not interpreted.

## Provider, cost, and attribution

- Data: [ECB reference rates through Frankfurter](https://frankfurter.dev/providers/ecb/).
  The [API documentation](https://frankfurter.dev/) provides a public endpoint without an API key.
  Prism requests the fixed v2 EUR table with `providers=ECB`, not the blended default feed.
- Source software: [Frankfurter MIT license](https://github.com/lineofflight/frankfurter/blob/main/LICENSE).
  Prism consumes its public JSON API and includes no Frankfurter or GPL launcher source code.
- Data terms: [ECB copyright conditions](https://www.ecb.europa.eu/services/using-our-site/disclaimer/html/index.en.html).
  Results identify ECB / Frankfurter, their published date, and that these are daily reference rates.
  Cross rates and amounts are calculated by Prism from the supplied EUR table. No ECB logos are used.
- No account, subscription, paid API, or secret is required. Public API availability is not guaranteed.

## Network and offline behavior

- Native `get_currency_rates` accepts no renderer arguments. Only the fixed HTTPS table is fetched;
  original searches, selected pairs, and amounts remain on the device. No request occurs on startup
  or for ordinary launcher searches. The source necessarily sees the device's network request/IP.
- All windows share a native cache and serialized refresh. A table is reused for one hour and persisted
  in the app cache as `currency-ecb-v1.json`; no user queries or converted amounts are persisted.
- After a refresh failure, a cached table can be used only while both its fetch time and rate date are
  no more than seven days old. The result visibly says `Cached · refresh unavailable` and retains the
  actual rate date. No cache or an expired/invalid table produces a recoverable provider failure.
- Failed refreshes have a 15-second backoff. Retrying during that interval does not send more requests.
  Fresh cached data can still be used while offline; it keeps its rate date rather than claiming a live quote.
- HTTPS only, no redirects, four-second network timeout, 64 KiB response limit, positive finite rates,
  one common valid date, EUR base, and unique uppercase currency codes are enforced in Rust.
- Only the currency provider receives a five-second search deadline. Local providers keep their
  500 ms default and publish independently. Cancelled searches cannot paint late currency results.

## Next additions

| Priority | Capability | First useful scope |
| --- | --- | --- |
| 1 | Percentage and time-zone conversion | Units and decimal grouping are [implemented](unit-conversion.md); `20% of 150` and explicit Seoul/New York time conversion remain next |
| 2 | Files and folders | Search chosen roots; open, reveal, and copy paths; cancelable indexing |
| 3 | Saved links | Aliases for websites, folders, and query templates; edit and persist |
| 4 | Text snippets | Korean/English search, preview and exact copy/paste; expansion comes later |
| 5 | Favorites and recent actions | Pin frequent commands and repeat useful actions without typing full names |
| 6 | Emoji and symbols | Korean/English names, recent choices, exact composed-sequence copy |

These are next priorities, not features marked complete. Existing IME, shortcut conflicts, clipboard
reuse, window behavior, and native visual acceptance remain quality work alongside new capabilities.

## Verification on 2026-09-06

- `pnpm test`: 94 tests passed, including parsing, cross-rate rounding, exact copy, dated/cached UI,
  query cancellation, and independent local/network deadlines.
- `pnpm typecheck`, `pnpm build`, and Rust Clippy with warnings denied passed.
- `cargo test --lib`: 70 passed; the explicit live-network test remains ignored by the ordinary suite.
  Currency tests cover invalid tables, freshness, cached failure fallback, and cache serialization.
- An explicit run of `currency::tests::live_reference_table` passed against the real HTTPS service,
  returning the 2026-09-04 ECB table with 30 currencies.
- A debug app built with the existing local-server configuration was signed and applied at the original
  app path. The Vite server was retained. These checks do not claim visually observed native keyboard,
  clipboard, or offline network-toggle behavior; DOM interaction tests mock native IPC.

### Result presentation follow-up

The expanded result view passes 96 frontend/core tests, type checking, and a production build.
Headless Chrome screenshots of the existing Vite app with mocked native IPC cover the calculator,
single currency conversion, four-currency overview, a long decimal result, and light/dark themes.
At 760 × 500, all checked views fit without horizontal overflow; the overview needs no vertical scroll.
These screenshots use fixture amounts and are visual evidence, not current exchange-rate quotes or
native WebView/clipboard proof. The existing Vite and Prism processes were retained for this UI update.
