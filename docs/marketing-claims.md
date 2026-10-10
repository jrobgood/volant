# Marketing claims — October 7, 2026 (0.2.0)

## Promise and release boundary

Keep work moving without leaving your flow: apps, answers, notes, and agents within reach. Keep the established “Your Mac. Your agents. One shortcut away.” headline and graphite/coral site system.

The public artifact is Volant 0.2.4, build 12 (October 9, 2026; build commit and notarization in `docs/release-quality.md`). It adds unit-math parentheses, daylight-saving explanations for time conversions, lazy notes loading, clipboard image capture alongside text, default-app handoff, per-copy app shortcuts and smaller fixes over 0.2.3 build 11, which added ACP conversation resume and the typing-pause fix over 0.2.2 build 10 (`e45903c`), which added the Volant menu, list edge fades under a translucent footer, the Herdr footer status, and the re-landed Notes editor theme colors. The rows below that were Coming next for 0.1.5 shipped in 0.2.0, verified against the notarized DMG: version, both architectures, stapled signature, iCloud key-value and loginwindow entitlements, and the embedded Developer ID profile. Advance claims only after verifying the actual distributed artifact; merging a website PR does not distribute a new app or publish the website.

| Story | In 0.2.0 | Evidence and limits | Website treatment |
| --- | --- | --- | --- |
| Apps, learned ranking, aliases, shortcuts, files, contacts, calendar | Yes | Existing native fixtures; hardware shortcut delivery is separate | Everyday launcher story |
| Markdown notes, encrypted clipboard, snippets, Raycast data import | Yes | Persistence and native fixture coverage; supported import types only | Useful things within reach |
| Basic arithmetic, units, timezone cards, city lookup | Yes | Core and native coverage | Existing download remains useful |
| Expanded percentages, dates, cooking, colors, fiat/crypto, answer reuse | Yes | #137–#149; signed rates helper fetched ECB, ExchangeRate-API and keyless CoinGecko; keyed CoinGecko path unverified | Answers as you type; New in 0.2.0 |
| Local Herdr status, supported Claude/Codex responses | Yes | Local installed response evidence and isolated routing checks | Actionable agent workflows; supported questions only |
| Saved remote Herdr machines | Yes | Fictional routing tests; compatible remote signed-app focus/answer smoke remains pending | Requirements and verification qualification in Agents docs |
| OpenCode, Claude Code, Codex ACP conversations | Yes | Existing verified provider paths; Claude/Codex require adapters | Separate new conversations from terminal panes |
| Resume the last ACP conversation | Yes, from 0.2.3 | #174; protocol fake-agent checks, model tests, native light/dark header fixture; owner resumed a real conversation in the installed app; only the latest conversation per provider and folder | Agents docs; no conversation picker claim |
| Cursor ACP | Launch path only | End-to-end verification pending | Explicit qualification |
| API/local models | Yes | HTTP and signed-helper fixtures; live authenticated provider/local inference remains separate | Implemented options, no blanket readiness claim |
| Apple Intelligence | Yes, eligible macOS 26+ | Signed sandboxed streamed probe; installed UI remains unverified | OS and eligibility requirement, docs limitation |
| Explicit note/clipboard-text attachments | Yes | #100; native picker and transport fixtures; live provider attachment prompt unverified | User-selected context, not automatic sharing; no snippets/files/images claim |
| Audio, connectivity, keep-awake, Settings panes | Yes | Native and functional fixtures; hardware and OS destination coverage is scoped | Everyday Mac controls |
| Color themes, Raycast theme import, themed Notes | Yes | #147, #148, #150; owner checked theme switching in the installed app | New in 0.2.0 |
| Lock, sleep, screen saver, restart/shutdown/logout | Yes | #102; native fixtures, sandbox probes, owner checked in the installed app | New in 0.2.0; OS confirmation for disruptive actions |
| Opt-in iCloud settings sync | Yes | #153 entitlement and Developer ID profile, present in the notarized 0.2.0 DMG; owner verified settings syncing between two Macs on October 7, 2026; quota and account-change notifications unverified | New in 0.2.0; selected settings only, no notes/history/keys |

## Privacy language

No Volant account or telemetry. Notes and encrypted clipboard history remain local. Submitted AI prompts and selected context reach the chosen provider/server. Keys stay in Keychain. Updates, HTTP AI and rates use separate helpers; opt-in iCloud uses Apple's system service. Avoid blanket “everything stays on your Mac,” “entirely offline,” or “zero dependencies” claims.

## Imagery

Existing hero and Notes assets are native fixtures. Added calculator, waiting-question, and unsent attachment-draft images come from the production SwiftUI views compiled with the release-optimized asset catalog, in a headless macOS 27 Tart guest. All stores, project names, session identifiers, note text, and questions are fictional. Agent input and network/provider connections are injected or absent. Light/dark captures are inspected separately. Render success is not a live provider, remote-machine, hardware, or performance test.

## Next concrete gaps

1. Done October 7, 2026: published the 0.2.0 website, verified DMG delivery, activated the signed build-8 appcast, and the owner completed 0.1.5 → 0.2.0 Sparkle upgrades on two Macs.
2. Complete compatible remote Herdr, real-provider attachment, and installed Apple/model checks under their own authorized test scope.
3. Refresh the original hero/Notes imagery in a future cohesive capture pass; do not reconstruct native UI in HTML.
