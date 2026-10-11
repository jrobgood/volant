# Cross-platform core: measurement and recommendation

The question was whether Volant could share a portable core across platforms with native display layers per platform (Swift/AppKit on macOS, Qt on Linux, something else on Windows), and whether WASM is the right vehicle for that core. This document records the measurement and the reasoning so the decision is not re-argued from instinct. Nothing here has been implemented.

Prompted by the competitor review in `docs/competitors.md`: Vicinae v0.29.0 (September 18, 2026) added Windows installer assets alongside its existing Linux and macOS builds, while Raycast ships macOS and a Windows beta with no Linux build. Vicinae therefore contests two of three platforms against Raycast, and no one contests its Linux position.

## What is actually portable today

Measured across `Volant/` and `Shared/` on September 19, 2026: 91 Swift files, of which 23 import nothing but Foundation — roughly a quarter. Those 23 are the algorithmic surface: `FuzzyMatcher`, `Frecency`, `Calculator`, `UnitConverter`, `EmojiIndex`, `MarkdownBlocks`, `CoreCommand`, `Preferences`, `PasteboardFilter`, `ExtensionApproval`, `AIConfiguration`, `PermissionGate`, and 11 of the 13 files in `Shared/`.

The remainder is platform integration, not incidental coupling: AppKit in 33 files, SwiftUI in 25, then Carbon hotkeys (6), CryptoKit (6), Combine (11), CoreAudio (3), CoreWLAN (2), Security (2), Translation (2), and single files reaching EventKit, Contacts, IOBluetooth, CoreServices, IOKit and Darwin. App enumeration, global hotkeys, pasteboard, Spotlight, contacts, calendar, and audio/Wi-Fi/Bluetooth control are what a launcher is. None of that ports.

The separation the question assumed already exists. What it separates out is the easy quarter, and the least differentiated.

## WASM is the wrong vehicle

Swift already compiles for Linux and Windows. Those 23 files build against swift-corelibs-foundation as they stand; CryptoKit's six call sites swap to swift-crypto, Apple's own drop-in with the same API. That baseline gives the shared core on three platforms with no marshalling, full type safety, and native speed, so WASM has to beat it rather than merely work.

It does not. The extension ABI is serialize-into-linear-memory, `run(ptr,len)`, read a length-prefixed record; `FuzzyMatcher` and `Frecency` run on every keystroke, and a WASM boundary there would give back more than the 10.6 ms the layout profile work recovered. It also adds a dependency: on macOS WASM is free through JavaScriptCore, but Linux and Windows would need wasmtime or wasmer bundled, against a README that currently claims zero dependencies. It cannot carry the other three quarters in any case, since pasteboard, hotkeys and Spotlight are not expressible in WASM and WASI does not reach them. And WASM currently means exactly one thing in Volant — untrusted extension code in a capability cage with a hash pin and manifest-declared imports — which is worth keeping unambiguous.

## The strategic objection

Portable core plus native UI per platform is Vicinae's architecture: a `src/server/` daemon with QML front-ends. Adopting it means competing with Vicinae as a worse Vicinae, two years behind and one developer against 296 forks, on their home turf.

It also costs the differentiator. App Sandbox, no network entitlement, no Accessibility grant by default, Carbon hotkeys and AppKit/SwiftUI are macOS-specific, and a portable core forces precisely the compromises that produce Vicinae's security posture — the thing `docs/competitors.md` records as structurally uncopyable from Volant.

## Recommendation

Extract the Foundation-only files as a dependency-free Swift package. The boundary already exists, so the cost is low, and the return is testability without the app plus a barrier against platform code leaking back in. Do this for hygiene and optionality, not as a port. Leave CryptoKit alone until a real port makes swift-crypto worth the churn.

If a cross-platform play is wanted, it is the agent layer rather than the launcher. `Shared/` is almost entirely the agent surface — ACP types, agent protocol, Herdr client, response controller — and it is portable today by accident of good design. ACP is a protocol and Herdr speaks over a socket, so the integration burden is a socket and a process spawn rather than pasteboard and Spotlight. No incumbent occupies native agent session management, and coding agents overwhelmingly run on Linux machines, which is where the demand is.

The part of Volant that is already portable is the part that is already differentiated. The launcher is neither.

## Before acting on the agent-layer path

- `Shared/HerdrProcess.swift` imports Darwin and `Shared/HerdrQuestion.swift` imports CryptoKit; both need a portable substitute before `Shared/` compiles elsewhere.
- A Linux build of the agent surface must be proven against a real Herdr socket and a real ACP session, not a test double, before any cross-platform claim is published.
- No performance, footprint or platform-support claim from this document goes on the website until it is verified on the target platform. The competitor figures above are dated and should be rechecked rather than reused.

## What the extraction actually took — September 19, 2026

`Core/` is a dependency-free Swift package, `VolantCore`, built as a static library so it adds
no embedded framework and no new signing surface: the app bundle still embeds only
`Sparkle.framework`. It holds 21 files. Nineteen of the 23 Foundation-only files moved as they
stood; the other two files are the `Quicklink` and `Snippet` model structs, lifted out of
`Volant/Quicklinks/Quicklinks.swift` and `Volant/Snippets/Snippets.swift`. Those two structs are
pure Foundation but sat in files that import AppKit, and `Preferences` cannot compile without
them. Their resolver and expander stayed in the app, where `NSWorkspace` and `NSPasteboard` are.

Four of the 23 candidates did not move, and the reasons are worth keeping:

- `HerdrClaudeQuestion` and `HerdrResponseController` both need `HerdrQuestion`, whose
  `fingerprint` hashes through CryptoKit. That is a single `SHA256` call standing between the
  Herdr surface and portability, and swift-crypto is the eventual answer rather than a
  substitute hash, which would change persisted fingerprints.
- `ExtensionApproval` calls `Integrity.sha256`, the same CryptoKit edge.
- `MarkdownBlocks` calls `LiveMarkdown.fences(in:)`, which lives in an AppKit file. The fence
  parsing in `LiveMarkdown.swift` is Foundation-only for about 110 lines before the AppKit
  styling begins, so splitting that file would move `MarkdownBlocks` too. That is a refactor of
  the Markdown editor and belongs in its own change, not bundled with a file move.

So the portable agent surface is 8 of 13 `Shared/` files rather than the 11 the measurement above
counted: the count was right about imports and wrong about the dependency graph behind them.

Every moved type became `public`, with explicit memberwise initializers where the synthesized
ones had been internal. `AIStreamDecoder.finished` became `public private(set)` because it is
observable state of a public type. Nothing else widened beyond what the app and its tests already
reached.

Tests: six test files, 22 tests, now run under `swift test` in the package with no app and no
Xcode project, in about 8 ms. `VolantTests` went from 129 tests to 107; the total is unchanged.
Four candidate test files stayed behind because they reach app types (`UsageStore`, `AgentsModel`,
`ACPModel`, `HerdrProcess`) alongside core ones.

Tooling: eleven ad-hoc `swiftc` checks under `tools/` used to list core files by path. They now
build the package once and link it through `tools/core-module.sh`, which fails loudly if the
module is missing rather than producing a confusing "cannot find type" error. `tools/test-scope.py`
and its tests were repointed at the new paths, and `Core/*` counts as a native change.

### Next candidates

- `QuicklinkResolver` is Foundation-only apart from its one-line `open(_:)`, which calls
  `NSWorkspace`. The URL scheme and Shortcuts-run validation in it is security logic that would
  benefit from package-level tests.
- Splitting `LiveMarkdown.swift` at the parsing/styling seam would bring `MarkdownBlocks` and the
  fence parser in.
- Moving to swift-crypto would bring the Herdr question cluster and `ExtensionApproval` in, and is
  the one change that makes `Shared/` portable outright.
