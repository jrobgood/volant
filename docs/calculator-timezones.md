# Calculator timezone conversion

The launcher now recognizes whole-query timezone expressions locally, without a service or new dependency:

- `1pm EST in CET` → `7:00 PM CET`.
- `1pm EST` or `1pm in EST` → the Mac's current timezone.
- `5pm ldn in sf`, `17:30 Europe/London to America/Los_Angeles`.
- `time in Tokyo`, `now in Dubai`.
- `2026-03-15 3pm Los Angeles in Berlin` → `11:00 PM in Berlin · Mar 15, 2026` (with localized date order).
- `7:30pm tomorrow` → `Tomorrow at 7:30 PM`, tagged with its weekday; `monday 9am` → `Monday at 9:00 AM`, tagged `In 3 days`.
- `tomorrow 9am EST in CET`, `9am EST tomorrow in CET` → `3:00 PM CEST · tomorrow`.
- `3pm Lisbon in Tokyo`: any IANA city name works without its region.

Results use a readable AM/PM clock, Midnight/Noon for exact boundaries, the requested abbreviation or city, and “your time” for the local destination. Same-day implicit conversions omit the date; day rollover adds tomorrow/yesterday relative to the user's local calendar day. Explicit-date queries retain a localized calendar date. Current-time queries compare destination day with the injected local day. Return copies the same readable answer through the existing Calculation row. Date omitted means today's date in the source zone. `local`, `here` and `my time` select the Mac's timezone. UTC and GMT are fixed offsets. Regional abbreviations (EST/EDT, PST/PDT, MST/MDT, CET/CEST, BST, JST) select their region's clock, like cities and IANA identifiers, and the label names the abbreviation in effect on that date: in summer `1pm EST in CET` is `7:00 PM CEST`.

Queries are limited to 256 UTF-8 bytes, consumed entirely, and evaluated only for explicit time forms. Ambiguous CST/IST/AST alone and ambiguous city names offer a card per region (see below), and daylight-saving gaps and repeated wall times are explained (see Daylight-saving transitions below). Broad country names, invalid dates and incomplete syntax produce no answer and no error row, so nothing appears while a query is still being typed. Supported city aliases are deliberately small and maintained independently; IANA identifiers provide broader coverage.

## Quality decision

Symptom: arithmetic and single-unit conversion could not answer everyday meeting-time questions.
Cause: neither existing evaluator represented a zoned instant.
Prevention: a separate Foundation-only evaluator owns strict grammar and injected clock/local zone. No permissive natural-language fallback steals application searches. Every copied answer retains the human-readable zone and relevant day context.
Evidence: automated core tests cover fixed offsets, implicit local conversion, city/IANA aliases, winter/summer and differing DST schedules, half-hour offsets, year/day rollover, invalid queries and DST gaps/overlaps. Native launcher fixtures check first-row selection, complete Copy output and incomplete-query behavior, and capture the affected row in light/dark appearances. The shared classifier treats timezone changes as UI-affecting. Actual verification outcomes are recorded in the PR.

## Presentation correction

Symptom: duplicate GMT/UTC offsets and ISO dates made a simple answer difficult to scan.
Cause: diagnostic detail was treated as the primary product answer.
Prevention: show the requested timezone abbreviation or a city name, natural clock text and only relevant day context. Keep exact instants in the typed result; do not put programmer diagnostics in the primary answer. This supersedes the earlier design proposal to always display date/offset metadata.
Evidence: exact output tests cover ordinary conversions, local destination, Midnight/Noon, tomorrow/yesterday and dated conversions. Native light/dark captures verify the actual result row; outcomes are in the PR.

## Regional abbreviation correction

Symptom: in October, with the Mac on CEST, `4pm in CET` answered `17:00 your time`.
Cause: abbreviations were literal fixed offsets, so CET was always UTC+1 even while Central Europe observed summer time. People use CET, EST and PST to mean the region's current clock.
Prevention: regional abbreviations resolve to a representative region zone; the label reports the standard or daylight abbreviation actually in effect, so a strict reading stays visible. This supersedes the fixed-offset rule proposed in `calculator-expression-design.md`. MST follows Denver, not Arizona; CST and IST remain ambiguous and offer a card per region.
Evidence: core tests cover the reported query, summer and winter labels, either spelling of a pair, and UTC against a regional zone.

## Calculator card

Every calculator answer (time, arithmetic, unit) renders as one card under a "Calculator" heading: the query on the left and the answer on the right, separated by an arrow, each with a detail tag. Time answers tag the query's weekday and date in its own zone (or "Now") and the answer's day as Today, Tomorrow or Yesterday, otherwise a weekday and date, prefixed "Your time" for the local zone. Arithmetic tags small whole numbers in words and larger ones with grouping. Unit conversions tag both unit names. Colons are dimmed so clock times scan as one number. Selection lightens the card instead of tinting it. Copy still puts the single-line answer on the clipboard. `CalculationAnswer` in VolantCore builds the card content and is tested there; the launcher fixture captures time, arithmetic and unit cards in both appearances.

## Relative days and city names

One day word may appear anywhere in a time query: today, tonight, tomorrow, yesterday, or a weekday (full or short name), which means its next occurrence with today included. It counts from the owner's local day, and an optional "at" next to it is ignored. A time with a day word needs no zone and resolves a local moment: the card reads `Tomorrow at 7:30 PM` (or the weekday name), tags the weekday or `In N days`, and Copy puts the absolute `Saturday, October 3 at 7:30 PM` on the clipboard, which still makes sense after it is pasted. Without a day word, a bare time stays unanswered, so `1pm` never takes over app search. Two day words, a day word with an explicit date, and `time in … tomorrow` are rejected. "next friday" is not supported, because people disagree on what it means.

City names come from four sources, in order: a small alias list (`ldn`, `nyc`, `sf`, `la`, `mumbai` and others), full IANA identifiers (`Europe/Lisbon`), the city part of every IANA identifier (`lisbon`, `buenos aires`), and `CityDirectory`, about 34,000 cities over 15,000 people from GeoNames.

## GeoNames city directory

Source: GeoNames `cities15000`, Creative Commons Attribution 4.0, credited in Settings → Data & Configuration → Acknowledgements. `tools/cities/build.py` downloads it and writes `Volant/Resources/cities.tsv.deflate` (raw DEFLATE, about 480 KB), keeping every city's name, ASCII name, country, admin1 code, population and IANA zone. Rerun it to refresh the data; it prints the source checksum for the PR.

Resolution: case, accents, periods and spacing are ignored ("st louis", "krakow"). A bare name resolves when every same-named city keeps the same clock (compared by January and July offsets), or the largest is at least twice the size of any that does not: Seattle, Barcelona (Spain over Venezuela) and Portland (Oregon over Maine) answer, while Springfield does not. A qualifier after a comma, or after a space, picks a US state or a country by code or English name: "Portland, ME", "Springfield MA", "Barcelona, Venezuela", "London, UK". Labels use the city's own name, so "3pm Tokyo in Barcelona" reads "in Barcelona", not "in Madrid".

Cost: nothing until a query names a city the built-in lists do not know. The first such lookup loads the table in about 60 ms and adds about 12 MB in a release build; later lookups take under 2 µs. Fixtures and unit tests use an empty or injected directory.

## Ambiguous cities

When a time question fails only because a city name is ambiguous in time, the launcher offers up to three cards, one per likely city, largest first: `time in springfield` shows Springfield, MO, MA and IL; `time in valencia` shows Venezuela, Spain and California. Each card's input is the qualified query, so Return copies that answer and Command-Return continues from it. US cities are qualified by state and others by country name, which never clashes with a state code; every alternative is checked to resolve on its own. Qualified answers name their qualifier (`in Portland, ME`). Only time-shaped queries look for alternatives, so ordinary searches never load the city table. "Time-shaped" means a clock with minutes or am/pm (or noon/midnight) followed by a word, or a `time in`/`diff` phrase; and the city and airport tables are consulted only for names made of letters and place punctuation, so arithmetic (`2 + 2`), units (`5 km`) and clock arithmetic (`10:30 + 2:45`) never load them. `CityDirectoryTests.testOnlyPlaceQuestionsLoadTheTables` guards this. Loaded, the city table holds about 3.8 MB of live allocations (entries are packed to 40 bytes) and the airport table about 0.7 MB (zone names are stored once).

## Ambiguous abbreviations

IST, CST and AST are still never resolved alone. A time question naming one offers a card per region instead, the same way: `5pm pst in ist` shows IST (India), IST (Ireland) and IST (Israel); CST shows US and China; AST shows Atlantic and Arabia. The qualified forms (`IST (India)`, `IST India`) are regions of their own and label the abbreviation in effect, so Ireland reads `GMT (Ireland)` in winter and Israel `IDT (Israel)` in summer.

## Airport codes

IATA codes resolve after every city source: `time in JFK`, `3pm LAX in LHR`, `diff NRT`. Labels name the city and code (`5:00 AM in New York (JFK)`). Data: mwgg/Airports (MIT), 7,918 airports with IATA codes, each with an IANA zone; `tools/cities/airports.py` writes `Volant/Resources/airports.tsv.deflate` (about 80 KB) and copies the license to `Volant/Resources/Licenses/Airports-LICENSE.txt`, which ships with the app and is credited in Settings → Data & Configuration → Acknowledgements. Because cities come first, a code that is also a city name (Ely, England versus ELY, Nevada) stays the city. The table loads on the first code the city sources cannot answer.

## Time difference

`time diff Tokyo`, `diff New York`, `time difference with Kolkata` compare a place's clock with the owner's right now: `7 hours ahead`, `6 hours behind`, `3 hours 30 minutes ahead`, or `Same time`, tagged with the time there (`6:00 PM in Tokyo`). Any name the converter resolves works, including regional abbreviations, which name the abbreviation in effect (`EDT is 6 hours behind`). Copy gives the sentence (`Tokyo is 7 hours ahead`). The offset is the current one, so it changes across either side's daylight-saving switch.

## Daylight-saving transitions

A wall time is never guessed. When a complete, parseable question names a time its source zone skips or repeats that day, the launcher explains instead of answering nothing:

- Skipped (spring forward): `2026-03-08 2:30am New York in Paris` offers one card for the nearest valid time, the instant clocks jump to: input `2026-03-08 3:00am New York in Paris`, answer `8:00 AM in Paris`, tagged `2:30 AM is skipped · clocks jump to 3:00 AM`. The rewritten clock keeps the owner's style (`3:00am` or `03:00`).
- Repeated (fall back): `2026-11-01 1:30am New York in Paris` offers a card per reading, `2026-11-01 1:30am (EDT) New York in Paris` → `6:30 AM in Paris` and `… (EST) …` → `7:30 AM in Paris`. Berlin reads `(CEST)`/`(CET)`. A reading names the region abbreviation where Volant knows one (EST/EDT, CET/CEST, GMT/BST, MST/MDT, PST/PDT), else the zone's alphabetic abbreviation (`CDT`), else `daylight`/`standard`, and `earlier`/`later` if a zone changed its offset without either; GMT-style offsets are never used.

These use the same card mechanism as ambiguous abbreviations and cities, so each card's input is a query that answers on its own: Return copies its answer and Command-Return continues from it. A reading in parentheses straight after the clock and followed by the source zone picks one side of an overlap, and must name the reading actually in effect, so `2026-07-01 1:30am (EST) New York` and `(EDT)` on a skipped time have no answer. With nothing after it, or only `in`/`to`, the parenthesized word is the source zone as before: `1pm (est)` and `1pm (est) in CET` read as `1pm est` and `1pm est in CET`. Cards therefore always write the source after the reading: `1:30am in New York` becomes `1:30am (EDT) New York`, and a question on the owner's clock gains `local` (`tomorrow 1:30am (EDT) local`, which reads like `tomorrow 1:30am`). Region choices and transitions combine: `2026-03-08 2:30am cst in utc` offers the corrected US card and the unaffected China card. An ambiguous abbreviation or city still offers at most three cards, even when its alternatives land on repeated times: `2026-11-01 1:30am cst in utc` shows US (CDT), US (CST) and China. Relative days and the local zone work too: on October 31 in New York, `tomorrow 1:30am` offers both readings.

Incomplete questions (`2026-11-01 1:30am New York in`, `… 1:30am (ED`) never reach the transition check, so no explanation or error row appears while typing. Core tests use an injected clock and local zone with fixed dates on both sides of the 2026 America/New_York and Europe/Berlin transitions; the launcher fixture captures the skipped and repeated cards.

## Next concrete work

1. Implement compatible mixed-unit arithmetic as designed in `calculator-expression-design.md`.
2. Add natural-language percentages and date/duration arithmetic, with explicit calendar policies.
3. Add currency rates only with a provider, timestamps and stale/offline behavior.

This implements the timezone slice, not full Raycast calculator parity. Signed installed-app verification and release distribution remain separate evidence/work.
