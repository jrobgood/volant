# Notes redesign — 2026-09-13

## Current behavior

The note fills one document surface. Actions, Browse and New share a compact header group, with space reserved for native window controls in the transparent titlebar. Browse (⌘P) and Actions (⌘K) now open as compact overlays inside the window; their height follows the available space. Escape, the close button, or clicking outside dismisses them. The footer hides successful-save chatter, but retains saving/error feedback, word count and an editor mode menu.

Live mode is the default. An AppKit NSTextView styles headings, emphasis, inline code and fenced code while preserving the original Markdown string. Markdown markers remain visible, with code fences subdued. This is a styled source editor, not a rich-text projection that hides syntax.

Type a line beginning with three backticks, then Return to write code. Even an unclosed fence is recognized. Closing with the matching marker length (or greater) returns following text to prose. Backtick and tilde fences are supported; longer outer fences can contain shorter fences. Live and Preview use the same fence parser.

When the cursor is inside a code block, a contextual footer bar provides a language dropdown and Copy Code. Choose Auto, Plain Text, Swift, Python, JavaScript, TypeScript, JSON, Shell, SQL, HTML, CSS or Markdown. Existing unknown language labels are preserved. Explicit choices change only the opening fence and participate in native undo/redo. Auto leaves the fence unlabelled, examines up to 16 KiB of code locally and falls back to Plain Text for ambiguous input. Detection is heuristic and token coloring is lightweight, not compiler-accurate. Code is never executed or sent to a service.

Markdown Source keeps monospaced editing available, while Preview renders Markdown without source markers. ⌘E toggles Preview. Duplicate, pin/unpin, raw Markdown copy, Reveal in Finder and Trash remain in Actions. Notes shortcuts are defined once (`NotesShortcut`). When a note command is unavailable (no note selected, an unreadable note, or an overlay open), the panel absorbs ⌘E, ⇧⌘C, ⌘D and ⇧⌘P rather than letting them fall through to the system alert. ⌘⌫ is left to text editing (delete to line start) and is only absorbed if it reaches the window unhandled. The Live editor's key handling is unchanged, so input-method composition, undo and selection are unaffected. Last selection and pins persist locally in UserDefaults, scoped to the notes directory; they are excluded from config/notes backups.

Save failures retain dirty text through reload and support retry. Closing remains prevented while saves fail. Trashing drains queued writes and saves dirty text first, preventing a late save from recreating a trashed note.

## Evidence and limits

- 48 tests passed, including immediate/open/closed/long fence recognition, multiple blocks, UTF-16 emoji/CRLF ranges, conservative detection, explicit overrides, Live/Preview fence parity, exact source preservation, language-change selection preservation, native undo/redo and source-mode restyling. Existing persistence/recovery tests also passed.
- Signed Release build passed: `build/Build/Products/Release/Vey.app`. This pass did not install, relaunch or notarize it.
- `NotesRenderTests` generates fictional hosted-view fixtures. [Current render fixtures](live-notes-review-2026-09-13/) include light/dark Live with an active Python block and language control, compact/default layouts, action overlay, Browse, Preview, empty, no-matches and error states. Active-code and action-overlay fixtures were visually inspected in both appearances, along with compact and error/empty examples.
- These renders are not desktop screenshots. The native language dropdown while open, titlebar placement, actual key focus/navigation, overlay transitions, IME input, paste/undo during composition and OS-level light/dark switching remain unverified because Computer Use has repeatedly timed out. Programmatic AppKit editing tests are separate evidence from end-to-end UI checks. Large-window fixtures request accessibility3 Dynamic Type; this does not establish actual macOS accessibility text scaling.
- Styling changes attributes without replacing source. Marked text is left to the input method until composition completes. Full hidden-syntax editing and a formatting toolbar are not implemented.

## Next concrete gaps

1. Live smoke test the new Release build using fictional notes: type opening/body/closing fences; select a language; undo/redo; switch among Live/Source/Preview; open and dismiss both overlays; verify copy and native window controls at minimum/default sizes and both OS appearances.
2. Verify IME composition, multiline paste, very long code lines and large documents. Add a user-adjustable text-size setting if platform text scaling is insufficient.
3. Consider hiding inactive Markdown markers only after source-to-display mapping, selection and undo are validated. Add formatting controls and broader language grammars as separate work.

## Quality decisions

- Invisible save failures/failed-create loss: storage errors previously had no visible recovery and failed creation was not dirty. Retain failed writes, show retry and cover recovery with automated tests.
- Queued-write/trash race: drain and save before trashing; never discard dirty state on failure.
- Cramped chrome: replace persistent sidebar and sheets with a single document, compact header group and bounded in-window pickers. Hosted render generation is automated; visual review and live window checks are not.
- Editor integrity: native editing APIs preserve undo, while styling touches attributes only. Source ranges use UTF-16 to match NSTextView. Language selection and Unicode regression tests automate the fragile paths.

Implementation reference: [Apple’s NSTextView editing contract](https://developer.apple.com/documentation/AppKit/NSTextView/shouldChangeText%28in%3AreplacementString%3A%29).
