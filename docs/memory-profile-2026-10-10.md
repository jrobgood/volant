# ACP polling and allocator profile — October 10, 2026

Issue #17 still had three open measurements after notes lazy loading shipped in #192: the cost of AI Chat's ACP polling, allocation sites in the agent and AI helpers, and the malloc fragmentation left in the October 7 profile. Everything below was measured with the opt-in fixture in `tools/memory`, fictional conversations and fictional files. No provider ran, no owner data or process was read, and no signed or installed build was used.

## What changed

While an ACP conversation is open, `ACPModel` asks the agent helper for the conversation every 0.25 s. Before this change the helper JSON-encoded the whole `ACPState` (transcript, tool entries, permissions) on every read, XPC copied it, and the app decoded it and compared it with the state it already had, even when nothing had changed.

- **The helper counts changes.** `ACPConnection.state` advances a revision on every change, including text appended in place to a message, through a property observer, so no change site can forget it.
- **Reads name the revision the app holds.** `acpRead(after:reply:)` replies with no data when the app already has the current revision, and with the encoded state and its revision otherwise. A negative revision always gets the full state.
- **The app skips unchanged replies.** `ACPModel.receive` decodes only replies that carry data. Any change the app makes to `state` itself (marking a sent prompt as working, cancelling, disconnecting, the Apple Intelligence path) forgets the helper revision, so the next read fetches the helper's full state. A no-data reply to a read that started before such a local change is treated as stale and read again, rather than confirming the app's own edit.
- **Unchanged:** the 0.25 s timer, the stale-read guard (`revision` and `generation`), session ownership, concurrent-prompt rejection and explicit permission cancellation, which all live in `ACPConnection` and were not touched. The BYOK/local AI helper keeps its full-snapshot `read(reply:)`; it polls only while a reply streams and stops when the turn is ready.

Streaming still sends the full state on every poll, because the state changed. That cost is measured below and left as a recommendation.

## Method

`tools/profile-memory.sh OUTPUT` built the optimized, ad-hoc signed fixture from this branch on `6af2aa8` and ran each workload in three fresh processes; tables show the median. Host: Apple silicon Mac16,6, macOS 27.0.1 (26A434), Swift 6.4, 128 GB.

**New allocation counter.** The fixture now counts every malloc and realloc through libmalloc's `malloc_logger` hook, so each phase reports bytes allocated and the number of allocations, including memory freed before the phase ends. Footprint and RSS still come from `TASK_VM_INFO`, live heap from `malloc_zone_statistics`, and the peak from 5 ms footprint sampling. These are different measures and are not additive.

**New ACP polling workloads** (`acp-poll-small`, `acp-poll-200k`, `acp-poll-1m`):
- **The conversation** is built by feeding ACP frames to the helper's real `ACPConnection`: 3, 40 or 190 turns, each a ~150-byte prompt, a ~4.8 KB reply streamed in 1 KB chunks, and three tool calls that start pending and complete.

  | Workload | Messages | Displayed text | Tool entries | Snapshot |
  | --- | ---: | ---: | ---: | ---: |
  | small | 15 | 15 KB | 9 | 16 KB |
  | 200k | 200 | 200 KB | 120 | 213 KB |
  | 1m | 950 | 949 KB | 570 | 1,011 KB |

  The helper caps displayed text below 1,000,000 bytes, so 1m is close to the largest conversation it allows.
- **Polling** goes through an in-process anonymous `NSXPCConnection` to a fake host that calls the same `ACPConnection` code as `AgentHost.acpRead`. Each reply hops to the main queue and is applied with the production `ACPModel.receive`, as the app does.
- **Phases:** the helper's encode alone ×40; the app's decode and compare alone ×40; 40 polls of the old full-snapshot read, idle and then streaming; 40 polls of the revision read, idle and then streaming. Streaming feeds four 48-byte chunks (about 770 bytes a second) between polls; feeding the helper is not counted. Each streaming phase lengthens the transcript by about 8 KB, so the later revision-streaming phase encodes a slightly larger state than the full-streaming phase.
- **Both sides run in one process**, so footprint and live heap include the helper and the app together. The separate encode and decode phases give each side's allocation and CPU cost.

**Allocator evidence.** `VOLANT_MEMORY_INSPECT=DIR` makes the fixture run `vmmap -summary` and `heap -s` on its own process after named phases, and `malloc_history` under `MallocStackLogging`. These were separate runs from the counter runs above, because launching the tools changes later phases. A standalone probe (not committed) fed the same frames to `ACPConnection` with prebuilt frames and recorded backtraces from the logging hook to attribute helper allocations.

**Commands:**

```sh
tools/profile-memory.sh OUTPUT
VOLANT_MEMORY_INSPECT=DIR VOLANT_MEMORY_INSPECT_PHASES=after_relief \
    "OUTPUT/Volant Memory Profile.app/Contents/MacOS/VolantMemoryProfile" SCENARIO
MallocStackLogging=1 VOLANT_MEMORY_INSPECT=DIR VOLANT_MEMORY_INSPECT_PHASES=transcript_built \
    "OUTPUT/Volant Memory Profile.app/Contents/MacOS/VolantMemoryProfile" acp-poll-1m
./tools/check-acp.sh
Scripts/test.sh --base origin/main --ui never
```

## Results

### 1. ACP polling

Per poll, median of three fresh processes. KiB allocated is total churn, not retained memory. Allocation counts were identical across repetitions and bytes within 1%; time varied by up to a third for the small workload and within 5% for 200k and 1m.

| Workload | Read | Allocated per poll | Allocations per poll | Time per poll |
| --- | --- | ---: | ---: | ---: |
| small | full, idle | 233 KiB | 317 | 0.21 ms |
| small | revision, idle | 31 KiB | 56 | 0.03 ms |
| 200k | full, idle | 1,615 KiB | 2,797 | 1.13 ms |
| 200k | revision, idle | 31 KiB | 56 | 0.03 ms |
| 1m | full, idle | 6,884 KiB | 12,704 | 5.10 ms |
| 1m | revision, idle | 31 KiB | 56 | 0.04 ms |
| 1m | full, streaming | 6,909 KiB | 12,815 | 5.14 ms |
| 1m | revision, streaming | 6,953 KiB | 13,005 | 5.13 ms |

At the app's four polls a second, an idle conversation went from:
- **small:** 0.91 MiB/s allocated and 0.8 ms/s of CPU time to 0.12 MiB/s and 0.1 ms/s;
- **200k:** 6.3 MiB/s and 4.5 ms/s to 0.12 MiB/s and 0.1 ms/s;
- **1m:** 26.9 MiB/s and 20 ms/s (2% of one core) to 0.12 MiB/s and 0.15 ms/s.

The remaining 31 KiB per idle poll is the XPC message and reply, the same for every transcript size. The CPU time is the sum of both processes in this fixture.

Where a 1m idle poll's cost went before the change, per poll:

| Side | Allocated | Time |
| --- | ---: | ---: |
| helper: encode the state | 5,051 KiB | 3.07 ms |
| app: decode and compare | 1,791 KiB | 1.80 ms, on the main queue |
| XPC transport and the main-queue hop | about 40 KiB | about 0.2 ms |

Streaming is unchanged: the state changes between polls, so the helper encodes and the app decodes it every time, about 27 MiB a second for a 1m conversation and 6.4 MiB a second for 200k while a reply streams.

Footprint, MiB, median (helper and app in one process):

| Phase | small | 200k | 1m | 1m live heap | 1m sampled peak |
| --- | ---: | ---: | ---: | ---: | ---: |
| baseline | 2.81 | 2.81 | 2.80 | 0.23 | 2.80 |
| transcript built | 4.00 | 8.61 | 26.69 | 2.47 | 26.69 |
| first full read | 4.39 | 10.08 | 32.02 | 3.62 | 32.81 |
| after encode ×40 and decode ×40 | 4.70 | 10.95 | 35.06 | 4.71 | 35.06 |
| after 40 full idle polls | 4.80 | 11.11 | 38.44 | 4.80 | 39.36 |
| after 40 full streaming polls | 5.91 | 11.27 | 38.75 | 4.89 | 39.72 |
| after 40 revision idle polls | 5.92 | 11.28 | 38.77 | 4.88 | 38.77 |
| released, after pressure relief | 6.17 | 11.38 | 38.88 | 0.63 | 38.88 |

- **Polling's retained footprint is bounded once the first read has happened.** Forty full idle polls added between 0.3 and 3.4 MiB to the 1m footprint across six fresh processes (this run's three and an earlier identical run's three), with a transient peak about 1 MiB above it while polling. Forty revision idle polls added 0.0 to 0.3 MiB and showed no peak. Live heap stays at the two copies of the state (helper and app) plus the fixture's own encoded copy.
- **The first full read is the footprint step:** +5.5 MiB for 1m, from the 1 MB encoded buffer and its growth, the XPC copy and the decoded strings.
- **After release, live heap returns to 0.63 MiB but footprint stays at 39 MiB.** That is allocator retention, not a leak: see section 3.

### 2. Helper allocation sites

**VolantAgentHost, ACP code only.** Measured in the fixture and probe with `ACPConnection` and fictional frames; the helper process itself was not run.
- **Each poll before this change**, encoding a 1 MB state allocated about 5 MB in 5,932 allocations: about 3.1 MB growing JSONEncoder's output byte array, 1.0 MB copying it into the returned `Data`, and about 0.75 MB of per-message keyed-container dictionaries. Decoding in the app allocated about 1.8 MB: 0.9 MB of message strings and the rest scanner buffers and array growth. The revision read removes all of this while idle.
- **Handling provider frames** allocated about 190 KiB per fixture turn (13 frames), independent of transcript size. In order of bytes:
  - `JSONSerialization.jsonObject` in `receive`: an 8 KB scratch buffer per frame, about half the total;
  - `JSONSerialization.data(withJSONObject:)` in `updateSession`, which re-encodes each tool update only to count its size against the 2 MB tool-detail limit: about 4 KB per tool update;
  - message text growing as chunks append;
  - `ChatPromptComposer.supportsEmbeddedContext`, which reparses the capabilities JSON on every prompt: about 8 KB per prompt.
  None of these is retained.
- **The 1m transcript build left 26.6 MiB of footprint over 2.5 MiB of live heap** (`vmmap`: DefaultMallocZone 24.5 MB dirty, 2.5 MB allocated, 91% fragmentation). This build includes the fixture generating its frames in the same process, so it bounds the helper's own fragmentation rather than measuring it.

**What could not be measured.** The helper processes themselves need what this environment doesn't have:
- `VolantAgentHost` runs only as an XPC service launched by launchd from a Volant bundle, and its listener accepts only Volant signed by team REMBT6JY4N. An ad hoc build is refused, as the October 7 VM run found. Its whole-process footprint, idle footprint and allocation stacks during a real conversation need a team-signed build installed in `/Applications` plus a provider executable at one of `ACPAgentResolver`'s fixed paths.
- `VolantAIHost` is the same: an XPC service in the signed bundle. Its conversation polls only while a reply streams, caps the transcript at 256 KiB, and encodes the same `ACPState` type, so the 200k streaming row above (about 1.6 MiB and 1.2 ms per poll) bounds its encode cost. Its process footprint and its URLSession and streaming allocations were not measured.

### 3. Malloc fragmentation on current main

The October 7 VM profile left about 73 MB of footprint over about 29 MB of live heap in the real app after a typing session. That VM app profile was not rerun here: it needs the Tart guest, which is reserved for the coordinator's serial UI runs. Instead, every fixture workload ran on current main with `vmmap -summary` and `heap -s` on the fixture process after `after_relief`. Footprint and live heap are medians of the counter runs; the zone columns (DefaultMallocZone, MB) come from one inspection run each:

| Workload | Footprint | Live heap | Zone dirty | Zone allocated | Fragmentation |
| --- | ---: | ---: | ---: | ---: | ---: |
| idle | 8.5 | 1.7 | 5.3 | 1.8 | 67% |
| emoji | 12.1 | 1.9 | 8.8 | 1.8 | 80% |
| clipboard | 97.6 | 0.4 | 9.5 | 0.4 | 96% |
| notes, 1,000 × 64 KB | 7.7 | 0.3 | 5.9 | 0.3 | 95% |
| notes, 300 × 4 KB | 5.1 | 0.3 | 3.1 | 0.3 | 90% |
| acp (400 snapshots) | 15.6 | 0.3 | 14.1 | 0.3 | 99% |
| acp-poll-1m | 38.9 | 0.6 | 36.6 | 0.3 | 100% |

- **Notes no longer dominate.** The notes workload's footprint after release fell from 183 MiB before #192 to 7.7 MiB, and its residue is ordinary small-region fragmentation. The October 7 VM run used 200 notes of 4 KB, so #192 is unlikely to have moved that VM figure much; that needs a VM rerun.
- **Clipboard's 97.5 MiB is not fragmentation.** After its 87 MB of image rows are released, `vmmap` shows 85.5 MB of dirty "Malloc Large (empty)": freed large blocks the allocator keeps for reuse. `malloc_zone_pressure_relief` returned none of them. Only 9.5 MB is small-region fragmentation. The app's clipboard path no longer decrypts image blobs to list them (the October 7 change), so this fixture row overstates the app.
- **Diagnostic pressure relief returned nothing in any workload**, the same as in the October 7 VM run. Small regions keep dirty pages that hold a few live allocations each, so they cannot be returned. Repeating a workload reuses them: idle revision polls after the first read added little.
- **Largest remaining source in the fixtures:** a long ACP conversation, at about 36 MB of fragmented small regions for a 1 MB transcript in one process. In the real app, only the decode side of that runs in Volant's process; the helper's frame handling and encoding run in VolantAgentHost.

## Recommended, not implemented

- **Send only what changed while streaming.** A streaming 1m conversation still moves about 27 MiB a second through encode, XPC and decode. The helper could return just the messages changed since the app's revision (normally the last one), and the app could patch its copy. This changes the protocol's contract and the stale-snapshot rules more deeply than the revision check, so it should be its own change with its own ACP checks.
- **Stop re-encoding tool updates to count their size** in `updateSession`, and parse the agent's capabilities once at initialization instead of on every prompt. Both are small, allocation-only savings in the helper.
- **Rerun `tools/memory/app-vm.py`** when the Tart guest is free, to see whether the VM app's 73 MB has moved since October 7, and run an installed, team-signed build to measure VolantAgentHost and VolantAIHost directly.

## Verified and not verified

- **Verified:**
  - The fixture numbers above, three fresh processes each, with the production `ACPConnection` and `ACPModel.receive`.
  - The fixture asserts that all 40 idle revision polls are answered without data, and that the app's state equals the helper's at the end.
  - `./tools/check-acp.sh`, with new checks that an unchanged conversation sends no snapshot, any other revision gets the full state, and the handshake, a prompt, a new message, text appended in place, a permission request and its answer, cancelling, the end of a turn and stopping each advance the revision, while an update for another session does not. All existing ACP checks pass.
  - `ACPSnapshotModelTests`: a new revision is applied and an unchanged one skipped; a local change forgets the helper revision; an unchanged reply to a read started before a local change is stale; replies without a usable snapshot are invalid; applied snapshots are still remembered for resume.
  - `Scripts/test.sh --base origin/main --ui never`.
- **Not verified:**
  - The signed, installed app and helpers over real XPC with a real provider. The fixture's anonymous in-process XPC connection serializes the same types but is not the launchd service.
  - SwiftUI's work when `state` changes; this change does not reduce it while streaming, and the fixture has no views.
  - Separate per-process footprints; helper and app share one fixture process.
  - The VM app profile and its fragmentation figure on current main.
