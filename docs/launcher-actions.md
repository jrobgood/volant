# Application and file Actions

The footer exposes Actions (⌘K); Reveal in Finder moves inside this searchable menu. ⌘↩ still reveals the selected result directly. The menu stays inside the launcher panel, with native button rows, keyboard arrows, Return, and Escape (close Actions first, then the launcher). Only displayed, implemented shortcuts have glyph hints.

Applications offer Open, Reveal in Finder, Show Package Contents, Add/Remove Favorites, Copy Path/Name/Bundle Identifier, Edit Shortcut & Alias, and Reset Ranking. Files offer Open, Reveal, Copy Path/Name, and Reset Ranking. Missing bundle metadata reports an error without changing the clipboard.

Favorites are stored as app paths in `favoriteApps` in configuration. The home screen shows installed favorites separately, preserving their configured order and avoiding duplicate Suggestions. Membership edits read the latest document, preserve unknown fields and other favorites, and reject stale membership. Reset Ranking drains queued usage writes and transactionally removes the app/file's Volant score and exact-query choices; Spotlight recency can still suggest the app afterward.

A menu captures stable result identity and revalidates before execution. Selection/query changes, removed results, and hiding the panel dismiss it. Bundle metadata is read only when Copy Bundle Identifier is activated; constructing the menu adds no startup discovery or background process.

## Creating snippets and quicklinks

`new snippet`, `create snippet` or `add snippet` (and the same with `quicklink`) list one Create Snippet or Create Quicklink command; both also appear under Commands, in matching searches, and at the end of the `snip` list. Return on the command opens a form in the panel, below the search field, in place of the results: snippets take a name, an optional one-word keyword and multi-line text with the supported placeholders listed under it; quicklinks take a name and a URL with a `{query}` hint. Return in a single-line field saves, Command-Return saves from anywhere (Return in the snippet text adds a line), and Escape or Cancel closes the form and returns to the unchanged search before Escape can hide the launcher. The panel handles Escape itself while the form is open, so Escape in the snippet text closes the form instead of starting NSTextView completion (an input method composing keeps its Escape). Closing the form puts focus back in the search field through AppKit: removing a focused form field leaves the window as first responder, where no key reaches the launcher. Typing a new search closes the form; re-entering the same text does not. While it is open the panel stays visible on focus loss, like the Wi-Fi password form.

`LauncherEntries` in VolantCore validates and writes the entry. Names are trimmed. A snippet name must be new among snippets; a snippet keyword or quicklink name must not match another quicklink name, snippet keyword or alias, must not be a reserved launcher word (`LauncherRouting`, which now also reserves the create phrases so import and editing agree), and a keyword is one word. Quicklink URLs must resolve the way quicklinks open today (`Quicklink.resolvedURL`, shared with the launcher and Raycast import): http or https with a host, mailto with an address, or a validated Shortcuts run URL, and no whitespace. The patch reads the latest config.json, compares its snippets, quicklinks and aliases against the snapshot taken when the form opened, appends one encoded entry to the raw list, and writes only if the result still decodes. Unknown top-level fields and unknown fields inside existing entries are kept; a missing `quicklinks` list starts from the default Google link rather than replacing it. A stale snapshot is rejected with the draft intact; the form takes the latest lists, and saving again revalidates against them.

After saving, the launcher uses the saved configuration at once and searches for the new item (its keyword, `snip <name>`, or the quicklink name's first word), so it is selected and usable, then reloads configuration as Settings edits do, which also lets iCloud settings sync pick up the change.

Edit and Delete for existing snippet and quicklink rows are not in Actions yet. Actions are built around application and file targets with a URL; editing would need the form's edit mode, a replace-by-identity patch and a delete confirmation, which is follow-up work.

## Volant menu

Clicking the Volant mark at the bottom left of the footer opens the launcher's own menu, anchored there inside the panel and styled like Actions. Its header names the running version ("Volant v0.2.1", read from the bundle), so it's always clear which build is installed. Items: Send Feedback (a new GitHub issue with only the app version, build and macOS version prefilled), Manual (usevolant.com/docs), Changelog (GitHub Releases), Check for Updates… (Sparkle, as in the menu bar), About Volant, Settings (⌘,) and Quit Volant (⌘Q). "Search for actions…" filters them. Arrows, Return and Escape work as in Actions; Escape closes the menu before the launcher, typing a new query closes it, and only one of Actions and the Volant menu is open at a time. Links open in the browser through NSWorkspace; the main app still has no network access.

## Scroll fade and footer

The results list runs the full height of the panel, and the footer is a translucent bar over it, so rows read as soft shapes and colors as they pass beneath it, as in Raycast. The bar is a within-window `NSVisualEffectView` blur at 60% opacity under a 20% theme tint, or the solid surface when Reduce Transparency is on. A SwiftUI material here, or the same blur at full strength, reduced rows beneath to a tint you could not see. A bottom content margin equal to the measured footer height lets the last row scroll fully into view above the bar, and the scroll indicator stops above it. The footer's controls sit on the bar, so they stay legible and take clicks over moving content.

The list fades at edges with more results beyond them (`EdgeFadeMask`, driven by `onScrollGeometryChange`): a 36-point band under the search field down to 25% opacity, and a 20-point band ending at the footer's top edge down to 70%. Rows beneath the footer stay fully drawn and the bar does the softening. At the start and end of the list nothing lies beyond, so the first and last rows are never dimmed. The fade is off when Reduce Motion or Reduce Transparency is on.

`tools/themes/render.swift` measures the bar in a window-server capture. It compares the luminance spread inside the footer (between the Volant mark and the action label) with rows beneath against an empty list, and checks the label contrast against the averaged footer background. It fails below a 2x spread or 4.5:1 contrast. October 8, 2026 on macOS 27: light 5.5 vs 0.4 stddev, 17.5:1; dark 9.2 vs 0.2, 10.5:1; Catppuccin Mocha 9.0 vs 0.0, 8.3:1.

## Verification

- `LauncherActionsTests` checks favorite persistence, unknown-field preservation, stale writes, ranking persistence, and stale action targets with isolated fictional stores.
- `LauncherEntriesTests` (VolantCore) checks appending, unknown-field preservation, the default quicklink list, stale snapshots, unrelated changes, uniqueness against snippets, quicklinks and aliases, reserved words, and accepted and rejected URLs. The launcher fixture opens both forms with Return, types the name natively, checks a duplicate keyword and an unsupported URL keep the form with an error, saves with Return against an isolated fictional config, finds the new item selected, and checks Escape cancels without writing; it captures the forms in light and dark.
- `LauncherAppMenuTests` checks the Volant menu's order, filtering, version header, feedback URL contents, link and command routing, and that it never shows with item Actions. The Actions fixture clicks the Volant mark, reads the version header (a fictional 0.0.0 fixture bundle), filters, activates with Return and checks the Escape order.
- `tools/check-launcher-actions.sh` compiles the production asset catalog using release optimization, then runs a separate native branded fixture in light/dark appearances. It is dispatched through headless Tart locally and the UI job in CI. This avoids changing activation behavior in the existing bare launcher fixture.
- Rendered screens, fixture keyboard evidence, and signed installed Finder integration are separate evidence. See the PR for results.

## Follow-ups

- Finder's Get Info integration, without unnecessary automation permission prompts.
- Broader configurable per-action keyboard shortcuts.
- App lifecycle actions, Auto Quit, and uninstall remain outside this everyday-actions scope.

## Recurring lesson

Symptom: the newer host compiler accepted the expanded LauncherView while Xcode 16.4 in Tart failed its expression type-checking budget. Cause: one large SwiftUI body combined content, overlay, and keyboard modifiers. Prevention: split content from interaction modifiers; keep the VM/compiler CI check. A host build alone is not compatibility evidence.
