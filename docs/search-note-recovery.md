# Search and note loading recovery

Issue #39: unchecked Spotlight start results left app discovery silently empty and file search callbacks retained. Failed UTF-8 reads omitted Markdown files entirely. These failures must be distinguishable from a healthy empty search.

App discovery checks start success, keeps existing app entries on refusal and exposes Retry Spotlight. Repeated starts do not add duplicate observers or restart a healthy index. File search reports a typed failure exactly once, releases its completion and debounce work, and cancels the old query immediately when a new search arrives. Launcher notices are scoped to the current query and remain visible alongside useful results. Retry never starts a command or opens a result.

Unreadable notes remain listed by filename with the same identity and pin. They have an explicit read-only unavailable view with Reveal in Finder; no empty placeholder may be saved over the file. Retry Loading Notes (⌘R) reads again and restores editing when repaired. Folder enumeration failure preserves the previous in-memory list and dirty edits. Only the open note and dirty notes keep their full text in memory; a note that becomes unreadable between reload and opening shows the same placeholder. Note search answers at once from titles, previews and resident text; body matches come from a cancellable background file scan whose results are dropped if the query or note list changed (see the [October 9 notes profile](memory-profile-2026-10-09.md)). Read errors remain separate from write/trash errors; retrying a read neither flushes nor discards a dirty edit. The existing UTF-8-only format is unchanged; no automatic encoding conversion or deletion occurs.

## Evidence and limitations

SearchRecoveryTests injects Spotlight start refusal without disabling the host service. Covers retry, retained app rows, callback release, cancelled/obsolete searches, launcher query scoping, invalid UTF-8 bytes, pin/selection retention, write/delete rejection for unreadable placeholders, repair and folder failure with dirty edits. Existing persistence tests continue to apply.

The native Actions fixture exercises app/file error notices, command-equivalent Retry, unreadable note selection/browsing and repair via ⌘R in headless Tart, using fictional files and no real Spotlight queries. Light/dark compact/default/large captures must be inspected separately from test success. UI classifier includes AppIndex, FileSearch and NotesStore. Real Spotlight service refusal and installed-app filesystem permission prompts are separate evidence and are not induced on the owner's machine.

## Prevention

A rejected asynchronous start must resolve its callback and release retained work. Empty results are not a failure signal. Failure to read a note is not evidence of deletion: keep identity, pins and bytes, and prevent placeholder edits. Keep each encrypted fixture database paired with its own process key. Automated native and UI fixtures cover these rules; screenshots still require visual inspection.
