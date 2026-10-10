# Notes memory profile — October 9, 2026

Issue #17 asked for notes to load lazily and for unchanged files to be reused. Before this change `NotesStore` kept the full text of every note in memory and read every file again on each reload: opening the notes panel, Retry Loading Notes, and every configuration change. Everything below was measured with the opt-in fixture in `tools/memory` and generated fictional notes. No owner notes were read.

## What changed

- **Listed notes keep metadata only:** id, URL, modification date, a disk stamp (modification date and byte size), the title (at most 80 characters) and the preview (the second non-empty line, now capped at 200 characters; rows show one line). The title and preview are computed once from the first two non-empty lines, by the same rules as before.
- **Full text is resident only where needed:** the note open in the notes panel, and any note with an unsaved or failed write. Selecting another note releases the previous clean note's text. A note whose save succeeds while another note is open releases its text too.
- **Reload reuses unchanged files:** a clean, readable note whose modification date and size match its last read is kept without opening the file. Changed files, new files and unreadable notes are read again, so Retry Loading Notes still repairs an unreadable note. The stamp is taken before the read, so a write during the read is picked up on the next reload rather than masked.
- **Search in two steps, never reading files on the main thread:**
  - `search` answers at once without reading any file. Exact matches come from resident text, unreadable filenames and remembered scan results. Every other note matches provisionally when its title or preview contains the term; both are cut from lines of the text.
  - `searchFiles` reads the undecided files on a background queue, one at a time, in list order. It stops once `limit` matches are certain and checks for cancellation between files. It delivers the exact list on the main queue only if its task wasn't cancelled. If the note list changed meanwhile (a generation counter), the scan is planned again against the new list instead of applying stale results.
  - The final list uses the same `localizedCaseInsensitiveContains` rule and order as before lazy loading. Per-file results are remembered as booleans, never text, for the four most recent terms while each file's stamp is unchanged.
- **Launcher `note` prefix:** shows the immediate matches, cancels the previous query's scan, and starts a new one. Results apply only if the launcher's query generation is unchanged. Body matches merge into the Notes section and keep the selected row by identity.
- **Browse overlay:** shows the immediate matches, cancels the previous filter's scan on each change, and uses the full-text results only while the filter and list generation still match. The highlighted entry keeps its identity when results arrive for the same filter.
- **AI Chat @ picker:** uses only the immediate search, so it never scans files. It reads text only for the eight or fewer notes it offers. Body-only matches in notes that aren't open are not offered.

Persistence rules are unchanged: dirty text always wins over disk and survives reload and folder failure; failed creates and updates stay dirty and retry; writes drain before trashing; unreadable notes keep their id, pin and bytes, show the read-only placeholder, and are never written. A note that becomes unreadable between reload and opening now shows that placeholder instead of an editor.

## Method

`VOLANT_MEMORY_SCENARIOS="notes notes-small" tools/profile-memory.sh OUTPUT` built the optimized fixture from `777deff` (before) and from this branch (after). Each workload ran in three fresh processes; the tables show the median. Host: Apple silicon Mac16,6, macOS 27.0.1 (26A434), Swift 6.4.

- **notes:** 1,000 notes of about 64 KB (about 61 MiB). The phases are:
  - load;
  - three reloads, each with an 8-result search for a word in every preview;
  - ten keystrokes typing a phrase no note contains (`absent fixtu` through `absent fixture phrase`), each one a new term searched on the calling thread;
  - three complete searches for that phrase, each of which must examine every file: in the after build, `search` plus `searchFiles`, waited for on the main run loop;
  - release.
- **notes-small:** the same phases with 300 notes of about 4 KB (about 1.2 MiB), closer to the 200-note VM profile.

The fixture creates a `NotesStore` without a notes panel, so no note is open; with the panel open, one more note's text is resident. Footprint, live heap and sampled peak are separate measures and are not additive.

## Results

1,000 notes, about 61 MiB, MiB:

| Phase | Before footprint | Before live heap | After footprint | After live heap |
| --- | ---: | ---: | ---: | ---: |
| loaded | 84.36 | 79.00 | 5.86 | 1.00 |
| after reload 1 | 163.83 | 79.05 | 7.17 | 1.05 |
| after reload 3 | 183.03 (166.5–201.6 across runs) | 79.06 | 7.17 | 1.05 |
| after 3 complete searches (sampled peak) | 183.03 | 79.06 | 7.34 | 1.17 |
| store released | 183.03 | 0.30 | 7.34 | 0.31 |

300 notes, about 1.2 MiB, MiB:

| Phase | Before footprint | Before live heap | After footprint | After live heap |
| --- | ---: | ---: | ---: | ---: |
| loaded | 5.59 | 1.89 | 4.19 | 0.47 |
| after reload 3 | 7.77 | 1.94 | 4.86 | 0.52 |
| after 3 complete searches (sampled peak) | 7.77 | 1.94 | 5.00 | 0.55 |

### Main-thread time per keystroke

This is the time on the calling (main) thread for each new term while typing a phrase that no note contains, the worst case for a search that must examine every note. It is the median of three fresh processes, in ms per keystroke.

| Build | 1,000 notes | 300 notes |
| --- | ---: | ---: |
| `777deff`, all text resident | 202.2 | 4.0 |
| this branch's first commit, files scanned on the main thread | 214.3 | 8.1 |
| this branch, immediate search only, files scanned in the background | 1.4 | 0.4 |

The first-commit row is the blocker found in review: once text stopped being resident, each keystroke read every file on the main thread. The final build answers from titles, previews and resident text, and the file scan runs on a background queue.

### Other timing

Median ms, measured as throughput in the fixture rather than interactive latency:

| Phase | 1,000 notes before | after | 300 notes before | after |
| --- | ---: | ---: | ---: | ---: |
| first load | 33.16 | 27.26 | 6.50 | 7.55 |
| reload 3 (with search) | 28.16 | 7.29 | 5.70 | 2.06 |
| 3 complete searches | 614.75 | 225.05 (background) | 12.05 | 8.63 |

The before build's footprint grew with every reload although its live heap stayed at 79 MiB: each reload allocated a fresh 61 MiB of text before the old copy was freed. The after build's footprint stays flat because unchanged files are not read.

A complete search still decodes every non-resident file once. The before build spent about 205 ms per in-memory scan of 61 MiB. The after build's three searches took 225 ms in total, almost all of it the first background scan; the second and third used the remembered per-file results. Peak footprint during that scan stayed at 7.34 MiB, so only one file at a time is resident.

## Verified and not verified

- **Verified:**
  - The fixture numbers above.
  - Hosted tests in `NotesStoreTests`:
    - listing with metadata only, and one resident note;
    - reuse of an unchanged file (made unreadable without changing its date or size, then reloaded without error);
    - rereading changed files, including a same-size edit with a new date;
    - search parity with the old full-text reference across resident, dirty, unreadable and on-disk notes, with and without a limit;
    - an immediate search that returns without calling a slow injected reader, with every read on a background thread;
    - a cancelled scan that never delivers, and a scan planned before a reload that is redone against the new list;
    - release after save;
    - the placeholder for a file that became unreadable before opening;
    - title and preview parity with the old rules.
  - `LauncherTypingTests` checks that title matches show before any file is read, that body matches merge in for the current query while keeping the selected row, and that an abandoned query's matches never arrive.
  - The existing persistence and recovery tests pass unchanged.
- **Not verified:**
  - The installed, signed app, and the VM app profile (`tools/memory/app-vm.py`); this is a model-only measurement.
  - Interactive latency: how quickly body matches appear while typing in a large notebook, and the Browse overlay's highlight when they arrive. Scans aren't debounced; a cancelled scan stops after the file it is reading.
  - An external edit that keeps both the modification date and the size is not detected until one of them changes. APFS records nanosecond modification dates, so this needs a tool that restores the date.
  - Notes panel rendering and keyboard behavior. `NotesRenderTests` is the UI fixture for them.
