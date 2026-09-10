# Local unit conversion and numeric grouping

Implemented on 2026-09-06. Unit conversion runs locally in both the desktop app and browser preview,
with no native IPC or network request. Results use the same expanded answer view as currency and
arithmetic, and Enter copies the displayed numeric value without grouping or a unit suffix.

| Family | Examples | Supported units |
| --- | --- | --- |
| Length | `10 cm to inch`, `1마일 킬로미터` | mm, cm, m, km, in, ft, yd, mi |
| Mass | `2.5 kg to g`, `1 lb to kg` | mg, g, kg, metric t, oz, lb |
| Temperature | `100 섭씨 화씨`, `32 F to C` | °C/C, °F/F, K |
| Volume | `2 L to mL` | mL, L, m³ |
| Duration | `2시간 분`, `1 d to h` | ms, s, min, h, d, wk |
| Area | `1 m2 to cm2` | cm², m², km², ft², ha |
| Data size | `1 GB to B`, `1 GiB to MiB`, `8 Mb to MB` | B/b; decimal k, M, G, T; binary Ki, Mi, Gi, Ti |

English full names and common Korean names are recognized for physical units. Separators include
`to`, `in`, `->`, `→`, `=`, or a space between source and target; Korean targets may end in `로` or `으로`.
Use unambiguous units: ounces are mass, tonnes are metric, and data symbols preserve case so `MB`
(megabytes) and `Mb` (megabits) never collapse into the same unit. Unqualified gallons, months,
compound units, and Korean number multipliers are not supported.

Inputs are limited to 160 characters, twelve decimal places, and an absolute amount of 10^12.
The parser validates comma grouping before removing separators. Different dimensions and temperatures
below absolute zero produce a provider failure. Unknown units are not guessed. Conversion results use
up to twelve significant digits to suppress floating-point noise; extreme magnitudes may use scientific
notation. Identity conversions preserve the parsed amount without conversion rounding.

Arithmetic now accepts correctly grouped literals such as `1,000 + 2,000`. It sends the canonical
expression `1000 + 2000` to the existing bounded native parser. The displayed expression and result
use thousands separators. Grouping works on decimal strings, retaining every native result digit,
trailing decimal zero, sign, and exponent. Copied arithmetic results retain the original native string.
Malformed input such as `1,00 + 2` is rejected rather than silently changing the user's amount.

Verification covers conversion constants, temperature boundaries, case-sensitive bits/bytes,
decimal/binary data sizes, invalid grouping, long decimal preservation, query correlation, cancellation,
and mounted answer/copy behavior. Browser screenshots with mocked native calculator IPC verify grouped
calculator results and local unit answers against the existing development server. This does not
substitute for native WebView/clipboard testing. No server or native app restart is required.

Next in the conversion scope: percentage expressions and explicit time-zone/date conversion. File
search, saved links, snippets, favorites, and emoji remain the subsequent everyday-workflow priorities.
