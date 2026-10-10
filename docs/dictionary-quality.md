# Dictionary definitions

`Define Word` is a branded core command. Select it or enter `define <word or phrase>`. The native view supports editable input, selectable definition text, explicit Copy Definition (⌘↩), Open in Dictionary (⌘O), Back (⌘[), and Escape dismissal.

Dictionary Services reads the Mac’s active dictionaries. Results are plain text from the first matching record; language coverage depends on enabled dictionaries. Missing words and unavailable dictionaries have the same API result. Volant suggests checking Dictionary → Settings and never falls back to a remote provider.

Lookups debounce for 200 ms and run serially on a separate actor. Cancellation skips queued calls; an already-running synchronous Apple call can finish, but its generation cannot overwrite a new query or cleared view. Input is limited to 256 characters. Leaving the command or dismissing the launcher clears transient input and results. Searches are not persisted or logged; copying is explicit.

The returned CFString is owned and released with `takeRetainedValue`. Ranges use UTF-16, reject overflow and partial surrogate pairs, and preserve explicit phrase input. Dictionary opening sends an escaped `dict` URL to the handler Launch Services reports for it, falling back to `com.apple.Dictionary` only when no handler is registered (see `Volant/Handoff/DefaultHandler.swift`); the scheme is declared by the installed Apple app. No private dictionary enumeration or HTML API is used.

## Evidence and remaining checks

- Universal Release build passed during implementation.
- Native Dictionary Services smoke lookup returned definitions for “serendipity”, “New York”, and “café”; a fictional missing word returned nil. Japanese text returned nil with this Mac’s active dictionaries, which is supported behavior.
- Deterministic model tests cover Unicode bounds, candidate ranges, command and URL parsing, explicit copy/open, missing results, retry, limits, and stale completions after edits/dismissal.
- `DictionaryTests.testNativeLookupNormalizesInflectionsAndKeepsPhrases` calls the real Dictionary Services path for plurals, inflections, surrounding punctuation and a phrase. It skips when the host has no active English dictionary, so a skip is not a pass.
- Branded native renders inspected in light/dark at 750×480 and 600×384: definition, empty, missing, error, and input-limit states. Footer actions remain readable at the minimum size.
- Local automatic UI selection correctly included the feature. Two attempts stopped at the existing `Actual launcher becomes key` assertion before reaching dictionary interactions. `--ui only` was a focused retry; final logic validation uses `--ui never` because the local UI limitation is tracked separately, not counted as a pass.
- Computer-use attachment to the isolated native preview failed twice with `cgWindowNotFound`. The preview was closed. Actual typing, Dictionary app handoff, and OS appearance switching remain unverified locally; CI keyboard fixtures are separate evidence.
- A signed installed Volant lookup and Dictionary app handoff remain separate from fixture/build evidence. The feature ships in the public 0.2.x releases.

## Regression lesson

Swift string-range conversion can accept a UTF-16 offset inside a surrogate pair. Validate UTF-16 boundaries explicitly before slicing. `DictionaryTests.testCommandAndUnicodeRanges` automates the regression check. The UI scope classifier includes `Volant/Dictionary/*` so changes to this surface select native UI checks.

## Normalized terms

Lookups pass the whole explicit input first, so a phrase is defined as written and Dictionary Services resolves plurals and inflections such as “geese” or “went” itself. When that returns nothing, the range from `DCSGetTermRangeInString`, starting at the first letter, is tried only if what it leaves out is punctuation, symbols or whitespace. This handles a trailing period or surrounding quotes without reducing “red zorblaxian” to “red”. A `kCFNotFound` range raises inside `DCSCopyTextDefinition`, so every range is validated before the call.

## References

- [Dictionary Services](https://developer.apple.com/documentation/coreservices/dictionary_services)
- [DCSCopyTextDefinition](https://developer.apple.com/documentation/coreservices/1446842-dcscopytextdefinition)
- [DCSGetTermRangeInString](https://developer.apple.com/documentation/coreservices/1450556-dcsgettermrangeinstring)
