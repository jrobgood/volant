# Launcher windows and pinned sources

## Behavior

- Command-comma is routed by the nonactivating launcher itself. All app-level
  Settings entry points hide the floating launcher before opening Settings.
  Hiding preserves ACP sessions and drafts.
- Ordinary launcher search dismisses on focus loss even with an ACP session
  retained in the background. A visible conversation or unfinished connection /
  translation form retains the previous focus-loss protection. Global mouse and
  workspace-activation observers exist only while the launcher is visible,
  covering the nonactivating-panel case where the previous app remained active.
- The launcher and notes panels share the floating level. Whichever panel was
  presented last is explicitly ordered directly above the other, so notes opened
  during a visible ACP conversation appears in front of it, and summoning the
  launcher puts it back in front. Neither panel activates the app, and ordering
  does not hide the other panel, end the conversation or change Escape: Escape
  in notes closes only notes.
- The top edge has a full-width native drag target and a small visible grip.
  The wing remains draggable. Existing edge/center guides provide nine placement
  combinations; Option bypasses snapping. Positions remain persistent and are
  clamped back onto a connected display when summoned.
- Status Bar settings independently pin Herdr and AI Chat activity. AI Chat is
  opt-in and identifies the source as AI Chat before showing the provider name.
  Unpinning a source never disconnects an active conversation. Herdr's provider
  filter remains an option within Herdr, not a separate status integration.

## Causes and regression prevention

Settings opened below the floating panel because the shared Settings handler did
not hide it. Menu shortcut routing alone was also insufficient for a nonactivating
panel. ACP connection lifetime had been used as a blanket keep-visible flag,
including when ordinary search was on screen. The automatic ACP activity strip
was outside the configured status-source list. Drag coverage previously called
the wing responder directly and did not establish window hit-testing.

Automated coverage includes native Command-comma dispatch and dismissal, retained
chat / ordinary search focus transitions, native window-dispatched dragging,
snap and position recovery, and independent source edits preserving unknown data.
Branded light/dark fixtures cover the drag grip and opted-in AI strip; native
Settings fixtures cover minimum dimensions. Build, rendering, fixture interactions,
and signed host behavior remain separate evidence.

## Next source integrations

The source list is already an array and preserves unknown source IDs. Keep it the
single pin configuration, with provider filters nested under the relevant source.
Before adding a third source, introduce a registry of source IDs, names, settings
views, summary state, and activation actions; render enabled registered sources
in saved order. Each source owns cancellation, refresh, permission prompts,
unavailable state, and its data lifecycle. Unknown sources stay saved but do not
create empty placeholder bars.

Next concrete backlog:

1. Calendar: next-event summary, chosen calendars, permission only on enabling,
   explicit open action, no event details in logs.
2. Home Assistant: user-selected entities / summaries, connection settings and
   secure credentials, bounded refresh, useful unavailable state.
3. Extension status contract: declared capability, source registration, bounded
   work, independent pin / unpin, and cancellation when no consumer remains.

Calendar and Home Assistant status providers are not implemented by this change.

## Installed verification

The owner confirmed physical summon, top-grip dragging and focus-loss dismissal
on September 18, 2026. Command-comma was also verified in the signed installed app.
