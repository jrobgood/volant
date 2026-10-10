# Calculator expression design review

Reviewed Numen at revision `36338ae87a8dfbdd0869d70eb6e7cd6c9c8f8771`. This is a capability and behavior review followed by an independent Volant design. No library dependency, implementation, parser, unit table, geography database or test code was copied. Volant functionality is unchanged by this document.

## What the review establishes

Numen emphasizes everyday expressions with units, dates, time zones, percentages and pluggable currency rates. Its README also describes programmer operators, English natural-language syntax, floating-point limits and locale inconsistencies. Those are useful product ideas, not a reason to import its implementation. [README](https://github.com/vicinaehq/numen/blob/36338ae87a8dfbdd0869d70eb6e7cd6c9c8f8771/README.md)

The README's statement that implicit conversion only works for currencies is stale relative to the reviewed tests: unit tests exercise addition across compatible units and mixed durations. They also demonstrate compound dimensions, target conversions and contextual unit interpretation. This review inspected assertions, not a running Numen build; test presence is evidence of intended behavior, not independent verification. [Unit behavior tests](https://github.com/vicinaehq/numen/blob/36338ae87a8dfbdd0869d70eb6e7cd6c9c8f8771/tests/unit.cpp)

Time-zone tests cover IANA identifiers, case/spacing variants, city aliases and geographically qualified places. They also assign some broad region/country names a single zone and treat EST as a New York alias. Volant should avoid those silent assumptions. [Time-zone behavior tests](https://github.com/vicinaehq/numen/blob/36338ae87a8dfbdd0869d70eb6e7cd6c9c8f8771/tests/timezone.cpp)

Date tests cover relative anchors, local-day boundaries, month-end clamping, leap-year shifts and machine-readable timestamps. These are useful acceptance categories for our own independently chosen examples. [Date behavior tests](https://github.com/vicinaehq/numen/blob/36338ae87a8dfbdd0869d70eb6e7cd6c9c8f8771/tests/datetime.cpp)

## Current Volant gap

`Calculator.swift` evaluates numeric expressions using its own tokens and reverse-Polish evaluator. `UnitConverter.swift` separately accepts one numeric measurement followed by one target unit. The launcher invokes both and formats their output into strings. There is no date/time value or quantity arithmetic. Consequently neither owner example can currently be evaluated.

The existing aliases and Foundation dimensions are useful, but the converter's split-on-text and lowercasing cannot be the grammar for a larger calculator. For example, `in` can mean inches or introduce a conversion, and unit case eventually matters for bits versus bytes.

## Prioritized behavior

| Priority | Capability | Independently chosen example | Expected behavior |
| --- | --- | --- | --- |
| First | Compatible mixed-unit arithmetic | `3kg + 5lbs + 4oz in oz` | `189.821886 oz`, rounded only for display |
| First | Explicit zone conversion | `3pm PST in CET` | `00:00 CET · next day`, using literal UTC−08:00 → UTC+01:00 |
| First | Date-aware regional time | `2026-03-15 3pm Los Angeles in Berlin` | Resolve both named zones for that date and show the destination date/offset |
| Next | Duration arithmetic | `2h 20min + 55min in hours` | `3.25 h` |
| Next | Everyday percentages | `18% of 240` | `43.2`; add unambiguous `off` and percentage-change forms separately |
| Next | Date arithmetic | `2028-02-29 + 1 year` | A documented end-of-month policy; calendar years are not fixed seconds |
| Next | Rates and compound units | `150km / 2h in mph` | Dimension-checked speed; incompatible dimensions fail clearly |
| Existing #4 | Currency arithmetic | `45 USD + 20 EUR in GBP` | Explicit rate provider, timestamp and stale/offline behavior |
| Later | Developer conveniences | Scientific notation, base conversions, modulo/bitwise | Preserve numeric precedence; add only with unambiguous syntax |

Mass reference: international avoirdupois pound = 0.45359237 kg and ounce = 0.028349523125 kg. The result above was independently calculated from those factors, not obtained from Numen. [NIST conversion tables](https://www.nist.gov/document/2026-nist-handbook-44-appendix-c)

## Independent implementation approach

Introduce a small calculation result type: number, quantity, duration, or zoned date/time, plus structured incomplete/error results. Keep the existing numeric functions and precedence tests. Add quantity-aware tokens and evaluation instead of replacing unit strings with numbers and hoping the scalar parser preserves meaning. Route explicit date/time forms to a dedicated date parser using Foundation `Calendar`, `DateComponents` and `TimeZone`. The launcher should receive typed results and a distinct copy value, not recover data from a display string.

A quantity carries its dimension, magnitude and display unit. Addition/subtraction require compatible dimensions, normalize operands consistently, then perform the operation and convert the final result to the requested unit. The first slice can support compatible addition/subtraction, scalar multiplication/division and parentheses; dimension-producing multiplication/division can follow. An explicit trailing conversion binds to the complete preceding expression. Without a target, preserve the first explicit operand's unit so display selection is predictable.

Use the current Foundation unit coverage where it passes reference checks; verify coefficients against exact standard factors for mass/length instead of assuming all library conversion factors have enough precision. Keep precision internally and round only in formatting. Decimal arithmetic is suitable for finite decimal factors and everyday monetary values; scientific functions may remain Double-based with documented tolerances. Do not promise arbitrary precision.

Define temperature separately: absolute Celsius/Fahrenheit conversions are affine, so adding two absolute temperatures must not be treated as ordinary mass addition. Initially retain single-temperature conversions and reject ambiguous temperature arithmetic. Distinguish ounces of mass from fluid ounces and US from imperial volume. Do not infer a missing unit in `3kg + 5`; do not reinterpret meters as minutes merely to make an expression succeed.

## Time-zone decisions

- Superseded: regional abbreviations now select their region's clock and label the abbreviation in effect; see `calculator-timezones.md`. The original proposal mapped them to fixed offsets (PST −08:00, CET +01:00), which put summer answers an hour away from what people mean.
- City/IANA forms use date-dependent rules from the OS time-zone database. Begin with a small independently maintained alias list plus IANA identifiers. Do not copy Numen's place database or silently choose a zone for a multi-zone country/state.
- Date omitted: use today's calendar date in the source zone and show that assumed date in the result. Preserve next/previous-day rollover and the resolved source/destination offsets. Support explicit ISO dates first; ambiguous numeric dates need locale-aware handling or a clearer input.
- Ambiguous abbreviations such as CST/IST and duplicate city names need disambiguation rather than a guessed answer. Offer explicit zones/offsets.
- Nonexistent spring-forward times should report that the local time does not exist. Repeated fall-back times should expose the two possible instants/offsets. Foundation provides matching/repeated-time policies; the UI must communicate the chosen interpretation. [Apple Calendar policy](https://developer.apple.com/documentation/foundation/calendar/repeatedtimepolicy)
- Inject the reference clock, source zone and locale into evaluation so DST and midnight tests are deterministic. Keep calendar days/months separate from elapsed durations: one local calendar day is not always 24 hours.

## Launcher and validation

Evaluate only recognizable calculator input, consume the whole expression, and impose input/token/depth limits. Incomplete typing is not an error banner. Do not let plain app names, unknown suffixes or malformed trailing input produce plausible numeric answers. Show the normalized interpretation with the result; Copy returns a deliberate value, including units or date/zone when relevant.

Backend work should first add pure tests without opening UI: the two requested examples, mixed dimensions, precedence/parentheses, negative quantities, division by zero, incomplete expressions, exact reference factors, DST gaps/overlaps, midnight/year rollover, ambiguous zones and locale variants. The clock and any currency provider must be injected. Wire results into launcher rows in a separate UI-affecting change, then run scoped keyboard, copy and light/dark checks. That makes the new conditional CI policy useful immediately.

No need to build a programming language, equation solver, variables or a broad natural-language interpreter for the first release. Start with the owner's two concrete expressions and make their semantics reliable.

## Correctness pass — October 5, 2026

A comparison with Raycast's advertised calculator found one arithmetic defect and several conversion-precision defects in existing behavior, all of which lacked tests.

- **Unary minus:** `-2^2` gave 4. Unary minus outranked `^`. It now sits between `^` and multiplication and is pushed without popping, so `-2^2` is -4, while `2^-1`, `2 * -3` and `-2 * 3` are unchanged.
- **Unit factors:** Foundation rounds several coefficients to about six digits (pound, ounce, stone, US gallon/quart/pint, fluid ounce, tablespoon, teaspoon, km/h, knot, horsepower, psi, mmHg). That surfaced in answers: `10 kn in kph` gave 18.519969, and `1 tbsp in tsp` gave 3.000008. `UnitConverter` now uses exact legal definitions for those units and Foundation for everything else, including the affine temperature scales. Cup is the US customary cup (236.5882365 mL); Foundation's 0.24 L is the US nutrition-label cup.
- **Coverage now tested:** remainder, floor/ceil/round of negatives, constants, nested functions, malformed numbers and unknown functions, number formatting (negative, fractional, infinity), every unit family against reference factors, temperature edges (-40, absolute zero, `°F`, spelled names), decimal versus binary storage, long and plural unit names, and accented city names with and without the city directory.

## Percentages — October 5, 2026

`%` is a percentage rather than remainder, matching how people write it and Raycast's calculator; remainder is `mod`. A percentage is a value that remembers it was written with `%`:

- `52% of 900` → 468, `20% off 80` → 64, `15% on 42` and `15% tip on 42` → 48.3. The card tags a tip with its amount ("Tip 6.3"); Copy gives the total.
- `+` and `-` with a percentage on the right take that share of the left side: `19 + 47%` → 27.93, `100 - 10% - 10%` → 81.
- Elsewhere `%` divides by 100: `200 * 15%` → 30, `50%` → 0.5.
- `of`, `off` and `on` require a percentage on the left and a plain number on the right; `52 of 900`, `50% of 20%` and `10 % 3` give no answer.
- The word operators share multiplication's precedence and associate left: `20% of 50 + 10` → 20.

## Dates and durations — October 6, 2026

`DateCalculator` answers date questions in the owner's local calendar and produces card content directly:

| Form | Example | Answer |
| --- | --- | --- |
| Day words alone | `now`, `today`, `tomorrow`, `yesterday` | the clock or date, tagged Today/Tomorrow |
| Counting | `days until 31 Mar`, `days since Jan 1`, `weeks until 2026-12-25`, `days between Jan 1 and Mar 1` | `176 days`, tagged with the target date; past targets read `643 days ago` |
| Offsets | `in 3 weeks`, `10 days from now`, `35 days ago`, `in 4 hours` | a date tagged `In 21 days`, or a clock tagged Today/Tomorrow |
| Weekday in N weeks | `monday in 3 weeks` | that weekday in the Monday-to-Sunday week N weeks from today |
| Date arithmetic | `August 5 + 5`, `5 Aug 2027 - 2 weeks`, `2028-01-31 + 1 month` | a plain number means days; months clamp to the month's last day |
| Clock arithmetic | `3:45pm + 5`, `9am + 90 min` | a plain number means hours |
| Timespans | `145 mins to timespan`, `100000 s as duration` | `2 hours 25 minutes` |

Rules: hours, minutes and seconds are elapsed time; days, weeks, months and years are calendar steps, so across the October 25 fall-back "in 1 day" still lands on midnight while "in 24 hours" lands at 11 PM. A date without a year means its next occurrence after "until", its last after "since", and this year elsewhere. Dates are `Mar 31`, `31 Mar`, `March 31st 2027` or ISO `2027-03-31`; numeric dates such as `12/25` are rejected because their order depends on locale. Day words count from the local day, and a weekday means its next occurrence with today included. Copy gives the headline, or the full date and time when an elapsed-time answer falls on another day.

Not yet: month-name-only queries ("days until March") and time-zone-qualified date arithmetic.

## Number input — October 6, 2026

`NumberLiteral` reads numbers for both the calculator and the unit converter, following the Mac's locale:

- Grouping is accepted only in real groups of three: `1,000`, `12,345,678`, `1,234.5` in English; `1,5`, `1,00` and `1,000,00` are rejected rather than guessed. The decimal separator is the locale's, so German reads `2,5` and `1.000` (a thousand) and rejects `1.5`. Spaces as grouping (French) are not supported.
- Scientific notation: `1e3`, `2.5E-3`, `1e+2`.
- Magnitudes in the calculator only: suffixes `k`/`K`, `M`, `B` and the words `thousand`, `million`, `billion` (`10K`, `2.5M`, `2.5 million`). Lowercase `m` and `b` stay meters and bytes, and the unit converter takes no suffixes, so `100k in c` is kelvin.
- Unit names ignore spacing: `sq ft`, `square feet`, `fl oz`, `nautical miles`. Square miles, yards, inches and centimeters were added.
- The converter tries every separator position, so `5 in in cm` reads inches.
- Calculator and converter tests now pass an explicit locale instead of depending on the machine's.

## Timestamps — October 6, 2026

`DateCalculator` also shows timestamps in local time. ISO 8601 with a zone (`2024-03-15T14:30:00Z`, `…-04:00`, fractional seconds, a space instead of `T`) or without one (`2026-10-07T08:00`, already local) gives the local clock, tagged with its date and, on the input side, how long ago or ahead it is. Unix time reads `unix 1700000000`, `1700000000 unix` or `epoch …`, as seconds, or milliseconds at 13 digits; `unix now` and `now in unix` give the current value. Bare numbers are never treated as timestamps, so arithmetic stays arithmetic.
## Functions and phrasings — October 6, 2026

- Functions: `sqrt cbrt abs round floor ceil`, `sin cos tan cot sec csc`, `asin acos atan`, `sinh cosh tanh asinh acosh atanh`, `ln`, `log` (base 10), `log10`, `log2`, `exp`. Names are case-insensitive.
- Angles are radians, matching mathematical convention; `°`, `deg`, `degree(s)` mark degrees and `rad`/`radian(s)` is accepted as a no-op: `sin(90°)`, `cos 60 deg`.
- A function name binds to the value right after it, so `sqrt 16 + 9` is 13 and `abs -3 + 1` is 4; parentheses widen the argument.
- Factorial: `5!` and `5 factorial`, for whole numbers 0–170. It binds tighter than unary minus and `^` (`-3!` is -6, `2^3!` is 64).
- Phrasings: `square root of`, `cube root of`, `power`, `to the power of`, `squared`, `cubed`.
- Results that are not real finite numbers (`sqrt(-1)`, `asin(2)`, `ln(0)`, overflow) give no answer instead of "undefined".

## Colors — October 6, 2026

`ColorCalculator` converts CSS colors: hex (`#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`), `rgb()`/`rgba()`, `hsl()`/`hsla()`, `hwb()`, `lab()`, `lch()`, `oklab()` and `oklch()`, in legacy comma or modern space syntax, with percentages, `deg`/`rad`/`grad`/`turn` hues and `/ alpha`.

- Hex answers in `rgb(…)` tagged with `hsl(…)`; other inputs answer in hex tagged with `rgb(…)` (or `hsl(…)` for rgb input). `in`/`to`/`as <format>` picks the target: `#ff6363 in oklch`.
- The card shows a swatch beside the input, outlined so pale and dark colors stay visible in both appearances.
- Math follows CSS Color 4: the sRGB transfer curve, lab/lch relative to D50 via Bradford, OKLab from linear sRGB. Tests check sRGB red against the specification's worked values and round-trip `#3a7bd5` through every format.
- hsl and hwb show one decimal so 8-bit colors survive a round trip (`hsl(0 100% 69.4%)`).
- Colors outside sRGB keep exact values in lab/lch/oklab/oklch and show their clamped sRGB color elsewhere, tagged "Outside sRGB". This clamps channels rather than gamut-mapping in OKLCH.
- Named colors (`red`) and hex without `#` are not read, since they collide with words and numbers.
## CSS and design units — October 6, 2026

`ScreenUnits` converts px, rem, em, pt, pc and the physical in, cm and mm they relate to: `2rem in px`, `32px in rem`, `12pt in px`, `2 inches in px at 72 ppi`, `1.5rem in px at 18px`. CSS fixes 1in = 96px, 1pt = 1/72in and 1pc = 12pt, and rem/em default to 16px; `at <n>px` sets the rem/em base and `at <n> ppi|dpi` switches to print and design math, where a pixel is 1/n inch. The input tag states the assumption (`1rem = 16px`, `72 ppi`). At least one side must be px, rem, em, pt or pc, so `1 pt in ml` stays pints and `5 in in cm` stays a length conversion. Results round to four decimals and copy in CSS form (`32px`).

## Use Answer — October 6, 2026

On any calculator card, Command-Return puts the answer (its Copy text) into the search field and keeps the launcher open, so `2 + 2`, Command-Return, ` * 3` gives 12. The footer labels it "Use Answer". Return still copies. The launcher fixture checks the label, the replaced query and the continued calculation.

## Currency — October 6, 2026

`CurrencyConverter` converts with European Central Bank daily reference rates (about 30 currencies, euro-based, one business day): `100 usd in eur`, `$100 in gbp`, `€50 to yen`, `USD1K in CHF`, `20 pounds in euros`. Cross rates go through the euro. The card tags the rate (`1 USD = 0.8 EUR`) and the rate date (`ECB rates · Oct 5`, or `Old ECB rates · …` after eight days), and Copy gives the formatted amount. Symbols and names map to one currency each ($/dollars to USD, ¥/yen to JPY); other dollars need their code. "pounds" is currency only when the other side is a currency, so `5 pounds in kg` stays a weight. Without rates there is no answer.

Network: the app keeps no network entitlement. `VolantRatesHost` is a sandboxed XPC helper with only `network.client`; its one method takes no input and fetches the fixed ECB URL with an ephemeral session (no cookies or cache), refuses redirects, caps the response at 64 KB and replies only with data that parses as the feed. `CurrencyRatesStore` in the app fetches nothing until a query is shaped like a currency conversion, then refreshes at most every twelve hours while conversions are used, waits an hour after a failure, and caches the rates with their date in the support directory so conversions work offline. When rates arrive for the query still being typed, the launcher redraws while keeping the selected row. `tools/check-rates-xpc.sh` runs the real signed helper from a built app inside a sandboxed client and fetches the live feed once.

The website's privacy page lists the app's network exceptions; the release that ships this must add exchange rates there.

## Named colors — October 6, 2026

The 148 CSS named colors convert when a target format is given: `red in hex`, `RebeccaPurple to rgb`, `light gray in hex` (spaces ignored). The input side is tagged with the color's hex. A bare name (`red`, `orange`) is left to search. The table in `NamedColors.swift` is generated from the color-name package (MIT), which mirrors the CSS Color 4 list.

## More dates — October 6, 2026

- `next friday` is the next Friday that is not today (one to seven days ahead), `this friday` the coming one with today included. Both work alone, in date questions (`days until next monday`) and in time queries (`3pm next friday`); the card always shows the resolved date.
- Workdays are Monday to Friday, without public holidays: `workdays until Dec 25` (also "business days", "working days") counts days after today through the target; `in 10 workdays`, `5 business days ago` and `today + 10 workdays` step over weekends.
- Named holidays work wherever a date does, with an optional year: Christmas and its eve, New Year's Day and Eve, Halloween, Valentine's Day, St Patrick's Day, Independence Day (`4th of July`), US Thanksgiving (fourth Thursday of November) and Western Easter (anonymous Gregorian algorithm). Alone, a holiday name is left to search.
- Durations add and subtract: `2h 20min + 55min` gives `3 hours 15 minutes`, `… in hours` gives `3.25 hours`, `2h 20min in minutes` gives `140 minutes`. A single quantity stays with `UnitConverter` (`90 min in h`), and negative totals give no answer.

## Multi-argument functions — October 6, 2026

`max`, `min` (two or more arguments), `atan2(y, x)`, `hypot`, `pow`, `log(x, base)`, `round(x, digits)`, `gcd`, `lcm`, `nCr`/`choose` and `nPr`/`perm`. A comma separates arguments when it cannot be thousands grouping (`max(1,5)`, `max(1, 500)`); `;` always separates, for locales with a decimal comma (`max(2,5; 7)` in German). Because max and min need two arguments, an ambiguous `max(1,500)` gives no answer instead of a wrong one. Arguments outside a function's domain (`nCr(3, 5)`, `gcd(1.5, 3)`, `log(8, 1)`) give no answer.

## Swap — October 6, 2026

Shift-Command-Return on a conversion card replaces the search with the same conversion the other way, using the answer as the input: `5 km in mi` becomes `3.106856 mi in km`, `100 usd in eur` becomes `80 EUR in USD`, `2rem in px at 18px` becomes `36px in rem at 18px`, and `#ff6363` becomes `rgb(255 99 99) in hex`. The footer shows "Swap ⇧⌘↩" only when a swap exists; arithmetic, dates and time answers have none. The unit converter now reads its own symbols (`ft²`, `°F`), so swapped queries parse. Round trips return to the original value within the six-decimal display rounding.

## Time and date polish — October 6, 2026

- Time conversions swap with Shift-Command-Return: `1pm EST in CET` becomes `7:00pm cet in est`; when the answer falls on another day there, the swap names that date (`2026-10-03 4:00am cet in est`) so the reverse is exact; an implicit local destination swaps as `local`. Clocks, local moments and differences have no swap.
- `time in 4 hours in Tokyo`, `time in 90 minutes in New York`, `time in 1 day in LA`: the clock there after that much elapsed time, tagged `In 4 hours`.
- `last friday` is the most recent Friday before today; `friday after next` is a week after next Friday. Both work alone, in date questions and in time queries, and past local moments read `7 days ago`.
- Locales that group digits with a space (French uses a narrow no-break space) accept a typed space: `1 000 + 5`, `12 345,5 * 2`.

## Public holidays — October 6, 2026

Workdays now skip the public holidays of the Mac's region where `PublicHolidays` knows them: US federal holidays (Saturday holidays observed Friday, Sunday ones Monday), UK bank holidays for England and Wales (substitute weekdays), and the national holidays of Germany, France and Canada (federal, with substitutes). The card says which ("Skips US holidays") or "Weekends only" for other regions. Rules are computed per year, including Easter-based days; one-off proclaimed holidays and regional (state or province) holidays are not included. Tests compare 2026 and 2027 against the OPM, GOV.UK, German and Canadian published lists.

More holidays work in date questions: Good Friday, Easter Monday, Boxing Day, MLK Day, Presidents' Day, Memorial Day, Juneteenth, Labor Day, Columbus Day, Veterans Day, Mother's Day and Father's Day (US dates).

## Crypto prices — October 6, 2026

Conversions include major coins: `0.5 btc in usd`, `100 eur in eth`, `1 bitcoin in ether`, `$100 in btc`. Coins are BTC, ETH, SOL, XRP, BNB, ADA, DOGE, USDT, USDC, LTC, DOT and TRX, by ticker or common name. Prices are euros per coin and cross with ECB rates for other fiat; coin amounts show up to eight decimals. Cards tag `CoinGecko · 2:00 PM` with the fetch time, and `Old CoinGecko prices · …` after an hour.

The rates helper's `fetchCrypto(key:)` requests a fixed coin list from `api.coingecko.com/api/v3/simple/price`; the optional key is its only input, redirects are refused and only a response that parses is returned. The app fetches crypto only for conversions naming a coin, at most every ten minutes (five after a failure, thirty after a 429), and never on launch.

## Keyless crypto — October 6, 2026

Crypto no longer needs a key. Without one, the helper calls CoinGecko's keyless public API (rate-limited per IP at roughly 10–30 calls a minute, far above Volant's ten-minute cadence). With the owner's free Demo key (Settings → Data & Configuration → Crypto prices, Keychain only, marked optional) the same request carries `x-cg-demo-api-key` for steadier keyed limits; a 10,000-calls-a-month Demo key stays well within its limit at about 4,300 calls a month of constant use. When CoinGecko answers 429 the helper replies `CryptoPrices.busyMessage` and the app waits thirty minutes instead of five.

Adding, replacing or removing a key clears the failure wait so the next coin query uses the new setting; other settings changes leave any wait in place. Removing a key keeps cached prices in memory and on disk, since they are the same public market data either way and keyless fetching continues. Both tiers require attribution: the card tag and Settings → Acknowledgements credit CoinGecko with a link. `tools/check-rates-xpc.sh` fetches crypto keylessly, or with `VOLANT_COINGECKO_KEY` when set.

## Fractions, Roman numerals and color adjustments — October 6, 2026

`NumberForms` answers explicitly requested number forms:

- Fractions: `0.25 as fraction` → 1/4, `1/3 + 1/6 as fraction` → 1/2, `2.75 as fraction` → 11/4 tagged `2 3/4`, and `as mixed number` swaps the two. The left side is any calculator expression. The answer is the closest fraction with a denominator up to 10,000, from the continued fraction and its best semiconvergent at the bound (the `limit_denominator` method), so `0.333333` gives 1/3 and `pi` 355/113. Answers more than a rounding error from the value are tagged "Approximate"; values of 10¹² or more give no answer.
- Roman numerals: `2026 in roman` → MMXXVI (whole numbers 1 to 3999), and `XIV in decimal`, `roman XIV` or `roman numeral MMXXVI` the other way, with swap between them. Only standard subtractive forms are read: a numeral counts only if writing its value back gives the same letters, so `IIII`, `VX` and `IC` give no answer. A bare `XIV` stays a search.

`ColorAdjustments` changes a color and answers in its own format (named colors in hex), or the format after `in`:

- `#f00 lighten 10%`, `darken`, `saturate`, `desaturate`, also `lighten(#f00, 10%)`: absolute steps in HSL lightness or saturation, as Sass does, so results match designers' existing stylesheets (`#ff3333`). OKLCH would keep perceived hue steadier but would disagree with every Sass and Less value people compare against. The input tag states the step (`Lightness +10% (HSL)`).
- `complement of #3a7bd5`, `#3a7bd5 complement`, `complement(red)`: HSL hue plus 180°.
- `#3a7bd5 at 50% alpha`, `with 50% opacity`, `at 0.25 alpha`: replaces the alpha.
- `mix(#f00, #00f)` and `color-mix(in srgb, #f00 25%, #00f)` follow CSS Color 5: OKLab by default, `srgb` and `srgb-linear` on request, premultiplied alpha, a missing percentage filled in from the other, and a total other than 100 scaled, with a total under 100 lowering alpha. Mixes answer in the first color's format.
- `contrast #fff #3a7bd5` (also `contrast ratio of white and navy`, `contrast #777 on #fff`): the WCAG 2 ratio of the first color as text on the second, tagged Passes AAA (7), Passes AA · AAA for large text (4.5), AA for large text only (3) or Fails AA. A translucent background is composited over white and translucent text over the background. The ratio is floored to two decimals, so `#777` on white reads 4.47:1 and fails AA, where tools that round show 4.48.

All of these need an operation word or function, so plain color names and words stay searches. The card's swatch shows the resulting color (the text color for contrast); there is no swap. `rgbToHSL` now treats channel spreads under 10⁻⁶ as gray, so OKLab mixes of grays do not show a stray hue.
## Number bases, list functions and date facts — October 6, 2026

**Number bases.** `NumberBases` converts whole numbers: `255 in hex`, `255 to binary`, `255 as octal`, `0x1F in decimal`, `0b1010 in hex` (also `hexadecimal`, `bin`, `oct`, `dec`). The calculator reads prefixed literals anywhere a number goes (`0x1F + 0b1010`, `max(0x10, 0b11)`, `0o17`), case-insensitive. Rules:

- Integers only, up to 2^53 in size, the range a calculator value holds exactly; fractions and larger values give no answer, as do malformed digits (`0b102`, `0x1G`).
- Negative numbers keep their sign (`-0xFF`) rather than a two's-complement pattern, which would need a word size the query does not state.
- Copy gives the prefixed form, with uppercase hex digits. Binary longer than a byte shows in groups of four on the card (`0b1111 1111 1111`) and copies without spaces.
- Converting to decimal needs a prefixed literal on the left, so `1010 in decimal` and `cafe in decimal` stay searches. `#ff6363 in hex` and `red in hex` stay color conversions.
- Swap converts back: `255 in hex` becomes `0xFF in decimal`, `0b1010 in hex` becomes `0xA in binary`. An expression on the left has no swap to decimal.

**List functions.** `avg` (`average`, `mean`), `sum`, `median`, `range` (max minus min) and `stdev` (`stddev`, the sample standard deviation dividing by n − 1, as spreadsheets' STDEV does) join the multi-argument functions. Like max and min they need at least two values, so an ambiguous `sum(1,500)` gives no answer. Phrases read as calls: `average of 1, 2, 3`, `sum of 3, 5 and 8`, `the average of 4 and 8`; "and" separates like `;`.

**Date facts.** `DateCalculator` answers questions about a date, in the local calendar with the injected clock:

| Form | Example | Answer |
| --- | --- | --- |
| Weekday | `what day was 2000-01-01`, `what day is christmas`, `what day of the week is Dec 25 2030`, `what day is it` | `Saturday`, tagged with the full date; "was" picks a yearless date's last occurrence, otherwise its next |
| ISO week | `week number`, `week of the year`, `what week is it`, `week number of Jan 1 2027` | `Week 41`, tagged with its Monday-to-Sunday span; `Week 53 of 2026` when the week belongs to another year |
| Day of year | `day of year`, `day of the year Dec 31` | `Day 279`, tagged `86 days left in 2026` |
| Days in | `days in february`, `days in Feb 2028`, `days in 2028`, `days in this month` | `28 days`, tagged with the month |
| Leap years | `is 2028 a leap year`, `is it a leap year`, `1900 leap year`, `next leap year` | `Yes`/`No`, tagged with the day count or the next leap year; Copy gives the sentence |
| Age | `age 1985-04-12`, `age April 12 1985`, `age 1985-04-12 on Jan 1 2030` | `41 years`, tagged with the next birthday or "Birthday today" |
| Difference | `Dec 25 - Oct 6`, `2027-01-01 - today` | `80 days`, negative when the first date is earlier |

Week numbers always follow ISO 8601 (weeks start Monday; week 1 holds the year's first Thursday), whatever the locale's own week rules, so the US Sunday-start convention is not used; the card says "ISO 8601". Age needs a birth year and a birthdate no later than the reference date; a February 29 birthday is reached on February 28 in common years, as Foundation adds years. A plain number after a date still means days (`Dec 25 - 5`).

## More units and forgiving input — October 6, 2026

- Astronomy: light-years (`ly`, `light year`), astronomical units (`au`) and parsecs (`pc`) use exact definitions: the IAU light-year of 9,460,730,472,580,800 m (a Julian year of light travel), 149,597,870,700 m for the au and 648,000/π au for the parsec. Foundation's coefficients are rounded to four digits, so these join the exact-factor table.
- Pressure and energy: the standard atmosphere (`atm`, 101,325 Pa), the torr (1/760 atm), `hPa` and `mbar`, and the International Table BTU (1,055.05585262 J). The thermochemical calorie (4.184 J) was already Foundation's.
- Mach: `1 mach in kph`, `mach 2 in mph`, `1500 km/h in mach`. Mach 1 is taken as 340.29 m/s, the speed of sound in the ISA sea-level atmosphere at 15 °C; the card's tag says so, because Mach really depends on air temperature.
- Speed of light: `speed of light` alone answers in m/s, and `c` means the speed of light only when the other side is a speed (`c in mph`, `0.5 c in m/s`, swapping back with `… mph in c`). Beside a temperature `c` stays Celsius, and `c in f` without a number gives no answer.
- Counts: `dozen` and `gross` are magnitude words in arithmetic (`2 dozen` → 24, `3 gross + 1`), and a count unit in conversions, where a bare number means items: `30 in dozens` → 2.5 dozen, `2 gross in dozen`, `3 dozen in each`. Swap writes the bare side as `each`.
- Units made here and Foundation's built-in units are now matched by dimension rather than exact class: Foundation's units are private `_NSStatic_` subclasses, so a class comparison rejected every pairing of a custom unit with a built-in one.
- Forgiving input: a leading `what is`, `what's` or `calculate`, and trailing `=` or `?`, are dropped before any calculator sees the query, so `what is 5 km in mi?` and `5 + 5 =` answer. The card shows the query without them.
- Missing closing parentheses at the end are supplied for arithmetic: `2 * (3 + 4` gives 14 and the card shows `2 * (3 + 4)`. An extra `)` still gives no answer, and an expression that ends in an operator or an empty call (`2 * (3 +`, `sqrt(`) stays unanswered rather than guessed.

## Raycast's remaining examples — October 6, 2026

Raycast's published calculator examples that had no answer, or a misleading one, now work in Volant's own way:

- `time` alone is the local clock, the same card as `now`. `time in 4 hours` and `time in 90 minutes` give the local clock after that much elapsed time, tagged `Your time · Today`; with a place (`time in 4 hours in Tokyo`) nothing changes.
- Nicknames label the city typed: `sf` and `san francisco` answer "in San Francisco" and `la` "in Los Angeles", both on Los Angeles time; `ldn`, `nyc` and `mumbai` likewise name London, New York and Mumbai.
- Ratios need the word "ratio", since `3:45` alone is a clock and `3 to 5` alone a range: `ratio of 3 to 5`, `ratio 16:9`, `1920:1080 ratio`, `4 to 6 ratio`. The answer is the quotient (0.6) tagged with the percentage and the lowest terms (`60% · 3:5`); decimals scale up to four places before reducing. A zero divisor gives no answer.
- Work periods: `workhours in 2027`, `work hours in May 2027`, `workdays in november`, `workdays this month`, `business days next year`. Workdays skip the region's public holidays as workday counts do, and a work hour total is eight hours per workday, tagged with the count and the holiday note. A month without a year is this year's.
- Hours as workdays: `55h in workdays` gives `6.875 workdays`, tagged `6 workdays 7 hours` and `8-hour days`; summed durations work (`2h 30min in workdays`) and `3 workdays in hours` goes back. Days and weeks are not converted, since a calendar day is not a workday.
- Swift colors: `in nscolor`, `in uicolor` and `in swiftui` give `NSColor(srgbRed: 1, green: 0.388, blue: 0.388, alpha: 1)`, `UIColor(red: …)` or `Color(red: …, opacity: …)`, with sRGB components to three decimals and the hex as the tag. Colors outside sRGB use their clamped color, tagged "Outside sRGB". These cards have no swap, since the initializers are not parsed back.
- Rates per unit of time: `8 dollars/hour in gbp` gives `£5.12 per hour`; `/h`, `per hour`, `a day`, `/month` and `/year` work, and the target may repeat the same unit (`in chf/month`). Changing the unit (`usd/hour in eur/day`) gives no answer, since a work day and a calendar day differ. Swap keeps the unit (`5.12 GBP/hour in USD`).

- Arithmetic on money: `MoneyCalculator` answers in one currency without exchange rates. `18% tip on $65` gives `$76.70` tagged `Tip $11.70`; `20% off $80`, `$65 + 18%`, `$20 * 3`, `$1,200 / 4`, `€50 + €20` and `£12.50 x 4` (also `×`) answer formatted like currency results. Amounts are a symbol before or after a number, an ECB reference currency's code before or after it (`usd 20`, `65 USD`, `USD1K`) or a currency name (`42 euros`); other words never take a number, so `20% off 80 usd` still reads 80 as dollars. The marks are removed and `Calculator` evaluates the rest. One amount multiplied or divided by another (`$100 / $20`) gives no answer (mixed currencies came later; see below); a bare amount (`$65`) is left alone.

`19m + 47%` still gives no answer: lowercase `m` stays meters, and `19M` is the magnitude.

## Cooking conversions — October 6, 2026

`CookingConverter` converts between volume and weight for about 55 common ingredients: `1 cup flour in grams` → 120 g, `250 g sugar in cups` → 1.26 cups, `2 tbsp butter in g`, `1 stick of butter in grams`, `1 cup honey in oz`.

- **Source:** weights per volume come from King Arthur Baking's [Ingredient Weight Chart](https://www.kingarthurbaking.com/learn/ingredient-weight-chart), read October 2026, and are kept in the chart's own measure, so the input tag quotes it: `All-purpose flour · 120 g per cup`, `Table salt · 18 g per tbsp`, `Butter · 113 g per stick`. Water alone uses 1 g per mL, since the chart rounds liquids to 8 oz a cup; milk, cream and other liquids keep the chart's 227 g.
- **Ingredients:** flours (all-purpose, bread, whole wheat, cake, self-rising, almond, rye, rice, coconut, semolina, cornmeal), sugars (granulated, superfine, packed brown, powdered, turbinado, demerara), butter, oils and shortening, water, milk, buttermilk, cream, sour cream, yogurt, cream cheese, honey and syrups, peanut butter, rice, oats, cocoa, table salt and both kosher salt brands, baking powder and soda, instant yeast, cornstarch, chocolate chips, nuts, raisins and coconut. Names match aliases, plurals and punctuation (`ap flour`, `icing sugar`, `Confectioners' sugar`, `packed brown sugar`). An ingredient the table doesn't know gives no answer instead of a water assumption, and a unit pair with no ingredient stays with the unit converter.
- **Kosher salt:** a tablespoon of Morton weighs twice one of Diamond Crystal, so plain `kosher salt` gives one card per brand instead of a guess; naming the brand gives one.
- **Units:** US cups, tablespoons, teaspoons, fluid ounces, pints, quarts, mL and L; g, kg, mg, oz and lb. `oz` is always weight and `fl oz` volume, so `1 cup honey in oz` weighs it. A stick is half a cup and only measures butter (`1 stick in grams` means butter). `metric cup` is 250 mL, here and in the unit converter (`1 metric cup in ml`).
- **Amounts:** recipe forms read as written: `1/2`, `1 1/2`, `1½`, `½`, and `a`/`an`/`one` (`a cup of brown sugar in grams`), with the locale's decimal and grouping separators (`2,5 cups sugar in g` in German, `1 000 g flour in cups` in French).
- **Answers:** three significant digits, and whole units from 100 up, since densities vary. A weight answer is tagged `Approximate`; a volume answer is tagged with the nearest kitchen measure (`About 1 ¼ cups`, eighths for cups, quarters for spoons and sticks). Swap gives the reverse with the ingredient (`120 g all-purpose flour in cups`).
- **Gas marks:** `gas mark 4 in c` → 177 °C (tagged `Gas mark 4 = 350 °F`, rounded to a whole degree), `gas mark 4 in f` → 350 °F, and `350f in gas mark` / `180 c in gas mark` → Gas mark 4, tagged `Nearest mark` when the temperature falls between marks. Marks are ¼ (225 °F), ½ (250 °F) and 1 to 10 (275 to 500 °F in 25° steps); temperatures more than 12.5 °F from any mark give no answer. Many charts print rounded Celsius values (180 °C for mark 4); Volant converts exactly from the Fahrenheit scale instead.

Not included: eggs and other counted ingredients, UK and Australian tablespoons (15 and 20 mL), cooked rice or packed versus sifted flour variants, and ingredient densities beyond the chart.

## More currencies — October 7, 2026

Conversions now cover about 160 currencies. ECB stays the source for the 29 it publishes (official reference rates); for the rest (AED, SAR, ARS, CLP, COP, TWD, VND, NGN, PKR, EGP, UAH, KES, QAR, KWD and so on) `WorldRates` uses ExchangeRate-API's open access endpoint, `https://open.er-api.com/v6/latest/EUR`.

- **Why this provider:** it has published terms that allow commercial use with attribution ("Rates By Exchange Rate API" linking to exchangerate-api.com) and permit caching but not redistribution; it needs no key; the euro-based response is about 3 KB for 166 currencies, updated once a day; and it documents its limit (a 429 that lifts after 20 minutes, never hit by a client asking at most twice a day). Frankfurter only republishes ECB rates. The fawazahmed0 currency-api on jsDelivr is CC0 but does not say where its numbers come from, and serving it through an npm CDN adds a dependency outside anyone's terms.
- **One source per conversion:** ECB when it has every fiat currency named, otherwise ExchangeRate-API for all of them, so a cross rate never mixes two providers' euro rates. `120 usd in aed` uses ExchangeRate-API's dollar too. Coins still cross through their CoinGecko euro price and whichever fiat source covers the other side.
- **Card:** tagged `Rates By Exchange Rate API · Oct 6` with the provider's update date, `Old rates by Exchange Rate API · …` after three days. Settings → Acknowledgements links the attribution.
- **Names and symbols:** only those that mean one currency: baht, rand, shekel, forint, ringgit, rupiah, naira, hryvnia, dong, taka, cedi, lari, tenge, ruble; ₦ ₴ ₫ ₪ ₱ ₸ ₾ ₽ ₵. Dirham, riyal, dinar, peso and shilling name several currencies, so those need ISO codes; ฿ is also used for Bitcoin and stays unread.
- **Fetching:** `VolantRatesHost.fetchWorldRates` takes no input, refuses redirects, caps the response at 32 KB and replies only when it parses as a euro-based success with at least fifty rates. `CurrencyRatesStore` fetches it only for conversions naming a currency ECB does not publish (`CurrencyConverter.needsWorldRates`, using the loaded ECB list or ECB's usual one), at most every twelve hours, an hour after a failure (longer than the provider's 20-minute limit), and caches it in `world-rates.json` for offline use. USD↔EUR and other ECB-only conversions never contact it.
- **Not included:** single-currency arithmetic (`MoneyCalculator`) still reads only ECB codes and the shared names, and ExchangeRate-API rates are daily mid-market figures, not bank or card rates.

## Numbers, percentage questions, unit arithmetic and clock spans — October 6, 2026

- **Large and tiny numbers:** whole numbers print in full up to 2^53, the largest range a Double holds exactly. Beyond that, and for non-zero values below a millionth, answers use scientific notation with at most ten decimals in the mantissa: `2^64` → `1.8446744074e19`, `100!` → `9.3326215444e157`, `1e-12` → `1e-12`. The card tags them `1.8446744074 × 10¹⁹`, and Copy gives the `e` form, which the calculator reads back in the owner's locale (`1,8446744074e19` in German). Previously `2^64` printed twenty digits, the last four invented. `sin`, `cos` and `tan` results within 1e-15 of zero now read as zero, so `sin(pi)` stays `0` instead of turning into `1.2246467991e-16`.
- **Percentage questions** (`PercentQuestions`): `20 is what percent of 80`, `what percentage is 20 of 80` and `what % of 80 is 20` → `25%` (tagged `20 of 80`); `20 is 25% of what` → `80`; `increase from 50 to 75`, `% change from 50 to 75` and `50 to 75 percent change` → `+50%` (tagged `Increase of 25`); `3/4 in percent` and `1/3 as a percentage` → `75%`, `33.3333%`. Each side is a calculator expression. Percentages round to four decimals. A change is measured from the first value, whichever word introduced it, and a change from zero or a share of zero gives no answer. The words `percent` and `pct` also read as `%` in arithmetic: `10 percent of 50` → 5.
- **New units:** days, weeks and years (`3 weeks in days`, `1 year in seconds`). A year is the average Gregorian year of 365.2425 days (31,556,952 s), and the card says so. Data rates: `100 Mbps in MB/s` → `12.5 MB/s`. Case decides bits or bytes, as in SI: `Mbps`, `Mb/s` and `Mbit/s` are bits, while `MB/s` and `MBps` are bytes. All-lowercase `mb/s` stays bytes, matching `mb` for megabytes, but `mbps` is bits because that's how it's written. Fuel economy: `30 mpg in l/100km` → `7.840486 L/100 km`, plus `mpg imp` and `km/l`. Running pace: `8 min/mile in kph`, `6 mph in min/mi`. Fuel economy and pace are reciprocal to their counterparts, so they convert through a reciprocal converter. Linear sides still use the exact factors, so `8 min/mile in kph` and `1 mile / 8 min in kph` agree. Feet and inches may be written with primes: `6' in cm`, `5'10" in cm`.
- **Unit arithmetic** (`UnitArithmetic`): `5 km + 300 m` → `5.3 km` (the first unit, or a target after `in`), `2 lb - 3 oz`, `5 ft 10 in in cm` → `177.8 cm`, `5 km * 3`, `10 mi / 4`, `10 km / 2 km` → `5`. A quantity over a time gives a speed or data rate: `1 mile / 8 min in kph` → `12.07008 km/h`, `10 km / 50 min` → `12 km/h`, `1 GB / 10 s` → `800 Mbps`. Without a target, speeds answer in mph after imperial lengths and km/h otherwise. Mixed quantities with no operator need a target, so a bare `5 ft 10 in` stays a search. Temperatures and reciprocal units don't add. Sums of durations alone stay with `DateCalculator`.
  - **Parentheses and precedence (October 9):** parentheses group, and products bind before sums: `(3kg + 5lbs) * 2 in oz` → `371.643772 oz`, `2 * (1 ft + 6 in) in cm` → `91.44 cm`, `10 km - (2 km + 500 m)` → `7.5 km`, `(10 km + 2 km) / 3 km` → `4`. A flat `5 km + 300 m * 3` now gives `5.9 km`; it used to scale the whole sum to `15.9 km`. The target still applies to the complete expression. Each step checks dimensions: like quantities add or divide into a number, a number scales a quantity, and a quantity plus a number, a product of quantities or mixed dimensions give no answer. An expression needs at least one quantity, so `(2 + 3) * 4` stays with `Calculator`, and unbalanced parentheses give no answer. A grouped quantity over a time is a speed or data rate, as in flat form: `(1 mi + 1 km) / 8 min` → `12.160284 mph`, `(10 km + 2 km) / 1 h in mph` → `7.456454 mph`, `(1 GB + 500 MB) / 10 s` → `1200 Mbps`. Without parentheses, `1 mi + 1 km / 8 min` adds a length to a speed and gives no answer; it used to give the speed of the whole sum.
  - **Reference and ounces:** `3kg + 5lbs + 4oz in oz` → `189.821886 oz` from the exact avoirdupois factors, rounded only for display. `oz` is always mass and `fl oz` always volume, so `8 oz + 4 fl oz` gives no answer while `8 fl oz + 4 fl oz in ml` → `354.882355 mL`.
- **Clock spans:** `9am to 5:30pm` → `8 hours 30 minutes`, tagged `9:00 AM to 5:30 PM`; also `from 9am until noon`, `between 9am and 5pm`, `09:15 to 17:45`, and `… in hours` → `8.5 hours`. Spans count wall-clock time and wrap past midnight: `3pm - 9am` and `10pm to 6am` are tagged `Overnight`. After `-`, the end needs am/pm, noon or midnight, because `3:45pm - 1:30` subtracts an hour and a half. Equal times give no answer.
- **Clock arithmetic with H:MM:** `10:30 + 2:45` is clock arithmetic, giving `1:15 PM`. That matches `3:45pm + 5`, where whatever follows a clock time is an amount of time. To add durations, write them as durations: `2h 45m + 1h 30m`.
- **Scaled durations:** a number scales the duration it touches, as in written math: `1h 30m * 3` → `4 hours 30 minutes`, `3 x 45 min`, `2h / 4`, and `2h 20min + 55min * 2` → `4 hours 10 minutes`.
- **Noon and midnight** work wherever a clock time does: `noon in tokyo`, `midnight PST in London`, `noon + 3`, `11:30pm to midnight`, `noon tomorrow`.

## Mixed currencies, pay for time and small forms — October 6, 2026

- **Mixed currencies:** `10 usd + 5 eur in usd`, `$20 + €15` (the first currency when there is no target), `£40 - $10 in eur` and `$20 + $15 in eur` convert each amount with ECB rates, ExchangeRate-API rates when a currency is outside the ECB list (`100 aed + $20 in usd`; one fiat source for the whole query, as conversions do), and coins with CoinGecko prices (`0.01 btc + $100 in eur`), then do the arithmetic. The input tag lists the rates used (`1 EUR = 1.25 USD`) and the answer tag the source (`ECB rates · Oct 5`, `Rates By Exchange Rate API · Oct 6` or `CoinGecko · 11:30 AM`). One-currency arithmetic reads every ISO code (`100 aed + 50 aed`, `TWD 500 * 2`) without rates; codes that are English words (CUP, PEN, TOP, KGS…) count only in capitals, so `5 cup + 2 cup` stays a kitchen measure. A missing rate means no answer, and arithmetic in one currency still needs none. Converted amounts follow the one-currency rules, so `$20 * €3` gives no answer.
- **Pay for time:** an hourly rate times a duration or a plain number of hours (`$5/hr * 40`, `$45/hour * 37.5 hours`, `90 min × €30/h`), and a duration times a plain amount, which reads as hourly (`2 hours * $40` → $80). The input tag shows what was multiplied (`37.5 hours at $45.00/hour`). Hourly pay counts only hours, minutes and seconds; a rate per day, week, month or year multiplies a plain number or a count of its own unit (`$200/day * 3 days`). `$200/day * 10 hours` and `$45/hour * 2 days` give no answer, since a working day is not 24 hours.
- **Shares in words:** `half of 30`, `a third of 90`, `two thirds of 12`, `a quarter of 200`, `three quarters of 80`, `double 21`, `twice 8`, `triple 7`. Everything after the word is the amount (`half of 30 + 10` is 20); it may be money (`half of $80`) or a duration (`a third of 2 hours` → 40 minutes). A percentage of a duration answers as one: `10% of 1 hour` → 6 minutes.
- **A temperature alone:** a number with a Celsius or Fahrenheit mark and no target converts to the other scale: `98.6 f` → 37 °C, `37 c`, `37°C`, `20 degrees celsius`. A number alone or with a bare degree sign stays as it was, since the scale is unknown. `c` is the speed of light only beside a speed (`c in mph`), so `5 c` is Celsius.
- **Ambiguous zone abbreviations:** IST, CST and AST are never guessed. A time question naming one gives a card per region, like an ambiguous city: `5pm pst in ist` offers IST (India), IST (Ireland) and IST (Israel); CST offers US and China; AST offers Atlantic and Arabia. The cards' queries (`IST (India)`, also `IST India`) read back as typed. BST stays British Summer Time, as before.
- **Rate fetches:** `CurrencyConverter.feedsNeeded` decides whether a query needs ECB rates or crypto prices after dropping the framing the calculator forgives, so `what is 100 usd in eur?` fetches on first use like `100 usd in eur`, and mixed-currency arithmetic fetches too; ExchangeRate-API is fetched only when one of those names a currency outside the ECB list. One-currency arithmetic never fetches.

Not included: trailing words after an amount (`2 dozen eggs`), a decimal separator setting (numbers follow the Mac's region), and other ambiguous abbreviations the zone table does not list.
