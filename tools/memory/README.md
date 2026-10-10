# Opt-in memory profiling

Run `tools/profile-memory.sh /tmp/volant-memory-NEW` from the repository. It compiles optimized production sources with an isolated entry point into an ad-hoc signed native fixture, then runs seven workloads three times in fresh processes. Set `VOLANT_MEMORY_SCENARIOS` (for example `"notes notes-small"`) to rerun only some of them. Requires macOS, Xcode tools and codesign. No UI is shown, no real clipboard/hotkeys/updater/provider starts, and storage uses temporary fictional fixtures with an injected encryption key. No owner data, Keychain tokens or process arguments are read.

Output includes CSV counters, environment/source identity, and a median summary. `python3 tools/memory/summarize.py OUTPUT_DIRECTORY` validates complete repetitions and regenerates the table. Measurements are opt-in; CI must not enforce machine-dependent memory or timing thresholds. `Scripts/test.sh --base origin/main` validates repository checks, while this script's compile/run and summary assertions validate the measurement fixture.

## Workloads

- Idle: production launcher model with empty fictional app/data stores, 3 seconds settled. This is not the full application's baseline.
- Emoji: 100 model search/reset cycles in batches of 25; each searches all/cat/heart/missing/all and moves selection 20 times per query. Uses the bundled catalog. It does **not** instantiate SwiftUI cells or open/close windows.
- Clipboard: 12 unique deterministic 1400×1400 RGBA PNGs, each below the production 8,000,000-byte compressed cap, then one text item. Load the newest 12 rows (11 images plus text); release rows; run 30 matching text queries. Writes drain between images. Seed/image-generation costs are explicitly separate phases, but allocator state still carries into later phases.
- Image decode: three highly compressible 4096×4096 PNGs. Use NSImage/CGImage and explicitly draw into full-size contexts, retaining three decoded images. This measures a full-resolution decode stress case, **not** SwiftUI's actual thumbnail renderer or a proven UI leak.
- Notes: 1,000 distinct Markdown files, each ~64 KB (about 61 MiB total). Load, then reload three times with an 8-result search each time, then type an absent phrase as ten new terms searched on the calling thread (main-thread time per keystroke), then run three complete searches for it that examine every file (immediate search plus the background file scan, waited for on the main run loop), then release. No owner notebook, open note or dirty writes. See [the October 9 profile](../../docs/memory-profile-2026-10-09.md).
- Notes (small): the same phases with 300 files of ~4 KB.
- ACP: 1,800 fictional messages/~890 KB text within current display limits; 400 encode/decode/equality cycles in batches of 100, matching full-snapshot processing. Runs sequentially in one process without provider, XPC, polling delay, helper, permission events or UI. Timing is throughput, not measured real-session CPU use.

## Counters and caveats

`TASK_VM_INFO` supplies physical footprint and RSS. Footprint is sampled every 5 ms; short-lived peaks can be missed. All-zone `malloc_zone_statistics` supplies bytes in live malloc allocations, not all VM/graphics memory or total allocation churn. An explicit outer autorelease pool is drained after each workload; this matters for bridged image objects in a command-line fixture without AppKit's event loop. A final `malloc_zone_pressure_relief(nil, 0)` is diagnostic only; it is not a proposed production strategy and does not guarantee footprint falls.

A retained footprint after object release does not establish a leak. Compare live allocations, repeated workloads, caches and VM behavior. Physical footprint, RSS and live allocation sizes are different metrics and are not additive. Solid-color images can have very different physical footprint and allocation size. Run Instruments Allocations/VM Tracker separately for stacks and VM attribution; do not compare instrumented absolute memory directly with the counter-only run.

The fixture is not the sandboxed/notarized installed app. Installed-app UI churn, provider/helper behavior, Intel and longer-duration growth remain separate checks. The profiling sources are included in the native change classifier; they do not select UI jobs because no UI surface changes.

## The real app in a VM

`tools/memory/app-vm.py` builds the Release app, signs it ad hoc without the iCloud entitlement, and runs it with `--memory-check` in the headless `volant-render-27` guest (see `docs/ui-testing.md` for its one-time SSH setup). The app pauses at fixed phases (at rest, launcher shown, 50 queries, Settings, closed, after a diagnostic pressure relief) while the guest records `footprint`, `vmmap -summary`, `heap --sortBySize` and the helper processes responsible to Volant, using generated notes and clipboard items only. Each run starts from an empty container and clipboard key. It prints the artifact folder; results are VM evidence, not the owner's installed app. See [the October 7 profile](../../docs/memory-profile-2026-10-07.md).
