# AI connections: ACP, BYOK and local models

## Behavior

Settings → AI offers ACP, BYOK and Local Models. Existing configuration migrates to ACP without changing its provider or project. Settings changes apply to the next conversation; an active chat and its draft retain their connection. AI Chat still uses Return to send, Shift-Return for a newline, the existing Markdown renderer, explicit cancellation and full-panel conversation UI.

ACP retains the existing CLI login, optional working folder and agent permission flow. BYOK supports OpenAI Responses streaming, Anthropic Messages streaming and custom OpenAI-compatible Chat Completions endpoints. Local connections use the compatible protocol on loopback. API chat is text-only; it does not inherit ACP's terminal/filesystem tools. The configured server receives the current prompt and previously completed turns. OpenAI requests use `store: false`; this is not a claim about every provider's retention policy.

API keys are stored in device-local Keychain generic-password entries keyed by provider and endpoint, never in config JSON or backups. Save Key and Remove Key report failures without replacing a working key on an update failure. Key bytes pass only to the selected helper connection/request. Custom endpoints require HTTPS, except explicit loopback HTTP. Redirects are refused, preventing keys/prompts from following redirects to another origin. No provider error bodies or source/response text are logged by Volant.

The separate `VolantAIHost` XPC service has App Sandbox plus outbound networking. The main app and WASM helper gain no network entitlement. Sessions are ephemeral, with no cookies, URL cache, background downloads or credential storage. Ending the connection cancels in-flight work. API snapshots stop polling once the conversation is ready; typing and launcher startup do not start network requests.

## Local detection

Opening Local Models in Settings probes the OpenAI-compatible model-list endpoints on loopback ports 11434 (Ollama convention), 1234 (LM Studio convention), and 8000 (generic local API). These are candidate server locations, not proof of a particular installed application. The list comes from the server; it does not mean every returned model is currently loaded or supports chat. Volant does not scan model files, launch services, download models, or start inference during detection. Custom loopback ports/base paths and optional local authentication are supported through manual fields and Test Connection.

Use selects a discovered server and model. Test Connection lists models on the selected endpoint; it verifies discovery/authentication, not a successful inference request. Unavailable, no-model and key-required servers remain explicit. Closing Settings, switching connection type, editing an endpoint or rescanning rejects late discovery responses. Detection does not enable or select a connection automatically.

## Resource and failure bounds

One turn at a time, at most 100 visible messages, 64 KiB per new prompt, 256 KiB transcript/history budget, 2 MiB stream wire budget, 64 KiB SSE line/event limit and a 180-second resource timeout. Model lists are capped at 1 MiB/1,000 entries. Stop cancels the turn and invalidates its generation; partial failed/cancelled responses stay visible but are excluded from future request history. Truncated streams are reported, never treated as complete. No automatic prompt retries or cloud fallback from Local Models.

## Verification and limitations

`AIHTTPTests` covers endpoint/credential isolation, provider request shapes, SSE completion/Unicode/error bounds, migration and stale discovery. `tools/check-ai-http.sh` runs the production transport/conversation against a fictional loopback server: model listing, streaming, concurrent rejection, cancellation, stale chunks, redirects, truncation and generic authentication errors. It runs through `Scripts/test.sh` in native CI. ACP regression checks remain required.

`tools/check-ai-xpc.sh` separately exercises the exported Developer ID helper through the production chat model and Settings discovery against that loopback fixture. It also checks a sandboxed client and an isolated fictional Keychain entry through save/read/replace/remove. It requires `VOLANT_AI_APP` and signing credentials, does not launch owner UI, and is not live provider authentication or inference evidence. Native Tart fixtures cover the affected Settings modes, local available/unavailable states, and chat in light/dark appearances without real credentials or servers.

Before claiming installed provider readiness, verify Keychain save/read/remove and a minimal user-authorized prompt through the signed installed app for each cloud provider and an actual local server. No live account, purchased API request, model download or installed-app restart is implied by fixture success. API key availability, model access, provider-specific context limits, reasoning/tool output, attachments and full compatible-server parity remain separate checks/features. Anthropic model pagination and richer local model state are follow-ups; manual model IDs are supported.

## Sources

- [OpenAI streaming](https://developers.openai.com/api/docs/guides/streaming-responses)
- [Anthropic streaming](https://platform.claude.com/docs/en/build-with-claude/streaming)
- [LM Studio model listing](https://lmstudio.ai/docs/developer/openai-compat/models)
- [Ollama OpenAI compatibility](https://docs.ollama.com/api/openai-compatibility)

## Quality decision

Keep the API transport separate from ACP so provider tools and CLI credentials cannot leak into BYOK/local requests. Preserve connection ownership across Settings edits, use explicit cancellation and validate the final streamed completion marker. Fake discovery/credentials are injectable in native fixtures; opening a preview must not contact owner servers or Keychain. Build, rendered UI, real HTTP, signed XPC and live provider evidence are distinct.

Fixture lessons: CI may start Python more slowly than a developer machine; use the configured test interpreter, a bounded 30-second readiness wait, and preserve startup diagnostics. Chat rendering fixtures need a real hosting window and semantic background before inspecting light/dark output.

## Apple Intelligence — September 21, 2026

A fourth connection kind, `apple`, runs Apple's on-device model through FoundationModels. It is the
only kind that needs no endpoint, no API key, no credential in the Keychain and no helper process:
the conversation runs inside the sandboxed app itself and never reaches the network.

Verified in a signed bundle carrying Volant's own entitlements, so App Sandbox is not in the way:
the model reported `available` and a streamed prompt returned its answer. That check matters because
the sandbox does block other system services; it was measured rather than assumed.

### Supporting macOS 15 and macOS 26 from one build

FoundationModels is macOS 26 and later while Volant's deployment target is macOS 15. Every entry
point is behind `#if canImport(FoundationModels)` and `#available(macOS 26.0, *)`, and the framework
weak-links, so an older Mac runs the same binary with the option present but unavailable.

`AppleFoundationModel.Availability` is the only thing the rest of the app asks. It answers `ready`
or `unavailable` with a sentence the owner can act on: the Mac is ineligible, Apple Intelligence is
switched off in System Settings, the model is still downloading, or the system is older than macOS
26. Settings shows that sentence rather than leaving a disabled button unexplained, and availability
is rechecked when a conversation starts, because it can be switched off between the two.

### Streaming is cumulative, not incremental

`LanguageModelSession.streamResponse` yields the complete text so far on each chunk, and it repeats
values and may rewrite them. Measured directly: a five-word reply arrived as seven chunks of
lengths 5, 9, 14, 20, 21, 21, 21. The first implementation here treated those as deltas, which would
have produced badly duplicated text in the transcript.

The conversation API therefore delivers a `snapshot` and the chat model replaces its assistant
message instead of appending. Unchanged snapshots are dropped rather than republished. This is the
opposite of the HTTP path, where `AIStreamDecoder` genuinely emits deltas.

### Not covered

Live use through the installed signed app, and behavior on a Mac where Apple Intelligence is off or
ineligible — both availability branches are reasoned from the framework's own enum rather than
observed. There is no model picker: the kind uses `SystemLanguageModel.default`.

## On-device dictation — September 21, 2026

`talk` in the launcher, or a hotkey of its own, records through Apple's `SpeechAnalyzer` and copies
the transcript to the clipboard. Audio never leaves the Mac and nothing is written to disk.

### What it costs, measured before it was written

Four questions were answered with signed probes carrying Volant's own entitlements, launched
through LaunchServices so nothing was inherited from a terminal.

- **Transcription in App Sandbox: free.** `SpeechTranscriber.isAvailable` is true, 45 locales are
  supported, and the system already had the assets installed, so there is no download and no
  entitlement. A generated sample transcribed accurately.
- **Microphone capture: one entitlement.** `com.apple.security.device.audio-input` plus
  `NSMicrophoneUsageDescription` and the ordinary microphone prompt. Verified by checking sample
  amplitudes rather than trusting `engine.start`, which returns OK *without* the entitlement while
  capturing digital silence — the same false positive `CGEvent.tapCreate` gives.
- **Hold-to-talk: free.** Carbon delivers `kEventHotKeyReleased` for a registered combination.
  Measured sandboxed with a real keypress: two presses, two releases, three-second and two-second
  holds. No Input Monitoring and no Accessibility.
- **Auto-insert into the focused app: opt-in, outside the main app.** Both routes, synthesising
  Command-V and writing through `AXUIElement`, need Accessibility, which the sandboxed main app never
  uses. By default the transcript is copied and the paste stays the owner's keystroke. Since Phase 1
  of [dictation typed at the cursor](dictation-at-cursor-design.md), choosing Type at the cursor
  hands finalized hotkey dictation to the separate `VolantInputHost` helper, which alone holds the
  grant.

### Behavior

`talk` toggles: Return starts listening, Return stops and copies. The dedicated hotkey does both
shapes — hold it for longer than 0.4 s and releasing stops, tap it and it keeps listening until the
next tap. From `talk`, the panel shows a live microphone indicator and the text heard so far, and
stays up through focus loss while listening or transcribing. From the hotkey (October 11, 2026),
the launcher is not shown: a small non-activating indicator near the bottom of the screen shows
Listening, the most recent heard text, Transcribing… and the result, while the app being typed in
stays frontmost and focused. See
[the hotkey indicator](dictation-at-cursor-design.md#hotkey-indicator-implemented). Either way,
dictation never runs invisibly.

The hotkey is recorded in Settings → General → Dictate Text and is unset until the owner picks one.
It joins the same duplicate checks as the other global shortcuts and app shortcuts, so one
combination cannot be bound twice. Escape while listening cancels and discards the transcript
without touching the clipboard; once transcription has started it runs to the end, because the
stop completion would otherwise still copy. For hotkey dictation, Escape is a Carbon hotkey
registered only while listening, so it works while another app is frontmost.

While listening, the default output is lowered to a fifth of its level and restored when listening
ends; Settings → General → Dictation → Lower volume while dictating turns it off. See
[lowering volume while dictating](system-control.md#lowering-volume-while-dictating-2026-10-10).

Availability is rechecked at start, because microphone permission can be revoked between uses. On
macOS 15 the command is present and reports that it needs macOS 26, the same pattern Apple
Intelligence uses.

### The availability gate is not the same as Apple Intelligence's

`canImport(FoundationModels)` works as a gate because that framework is absent from the macOS 15
SDK entirely. `Speech` is not: it has existed since macOS 10.15, so `canImport(Speech)` is true on
the older SDK while `SpeechAnalyzer`, `SpeechTranscriber` and `AnalyzerInput` are missing from it.
Gating on `canImport(Speech)` alone compiled here and failed on CI's macOS 15 runner with three
"cannot find type in scope" errors.

The gate is therefore `canImport(Speech) && canImport(FoundationModels)`, where the second
condition stands in for "built against an SDK new enough to see these symbols". Anything using a
macOS 26 API from a framework that also exists on macOS 15 needs the same treatment, and the
compiled-out branch should be type-checked deliberately rather than assumed.

### Microphone buffers must be resampled first

The first version shipped a crash. It installed a tap on the input node and handed each buffer
straight to `AnalyzerInput(buffer:)`. The microphone runs at the hardware rate, measured here at
48 kHz, while the analyzer's format is 16 kHz, and `AnalyzerInput` traps on a mismatch. The tap
runs on the realtime audio thread, so the trap took the whole process down rather than surfacing
as an error: `EXC_BREAKPOINT` in `AnalyzerInput.data(from:)`, every time dictation started.

`SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:considering:)` gives the format the
analyzer wants, and an `AVAudioConverter` resamples each buffer before it is yielded. The
conversion lives in `SpeechDictation.convert(_:using:to:)` rather than inline in the tap, so it can
be tested with synthesized buffers and no microphone.

Two rules follow from this. Nothing inside an audio tap may trap, so the conversion returns nil for
anything it cannot handle and the buffer is dropped. And a file-based test does not cover the live
path: `analyzeSequence(from: audioFile)` converts internally, which is exactly why the original
check passed while the real feature crashed.

### Not covered

Live dictation through the signed installed app, the accuracy of long transcripts, locale
selection on a Mac whose language the engine does not support, and behaviour when a microphone is
removed mid-session. `tools/check-dictation-hud.sh` renders the hotkey indicator from fictional
states; it does not render the in-launcher status line, press a real hotkey or Escape, or record.

## Attaching notes and clipboard text with @ — September 30, 2026

In AI Chat, typing `@` at the start of a word, or pressing the @ button, opens a picker over recent
clipboard text and notes. Arrow keys move, Return attaches, Escape closes and leaves the typed `@`
in place. An `@` in the middle of a word, such as an email address, is ordinary text, and none
opens the picker while an input method is composing. Choosing removes the `@` that opened the
picker and adds a chip showing the title and size; chips are removed with their button.

**Snapshots.** An attachment copies the text when it is chosen. Editing the note or copying
something else afterwards does not change what is sent. A note with unsaved edits contributes
the text on screen. Attachments stay in memory with the draft, survive focus loss like the draft,
and are cleared once the message is sent. Nothing is attached implicitly and nothing is logged.

**Per connection.**

| Connection | What the agent or model receives | Transcript |
|---|---|---|
| ACP agent advertising `promptCapabilities.embeddedContext` | One `resource` block per attachment (`volant://note/…` or `volant://clipboard/…`, MIME type, text), then the prompt | Prompt plus attachment titles |
| Any other ACP agent | One text block: each attachment in `<attachment kind title>` tags, then the prompt | Same |
| Bring your own key, Local Models | The inline form, which also stays in history for later turns | Same |
| Apple Intelligence | The inline form under a 6 KB budget | Same |

Sends without attachments use the original text-only calls unchanged.

**Limits.** 32 KB per item, 48 KB per message, 8 items, and 6 KB for Apple Intelligence's small
context. Oversized attachments are refused with a reason, never truncated, so an agent never
answers from part of a note without knowing it. Both helpers re-check the limits rather than
trusting the app, and a closing tag inside attached text is escaped so it cannot end its block.

**Not in this version.** Files, Herdr pane output and images. Files need care in the sandbox: ACP
agents can be given a link and read it with their own tools, but connections without tools need
the owner to grant access through an Open panel.

**Evidence.** Core tests for the composer, the capability check and the limits. `tools/check-acp.sh`
asserts the exact blocks for agents with and without `embeddedContext`, the short transcript, and
that a refused prompt sends nothing. `tools/check-ai-http.sh` sends a real request to a loopback
fixture and checks that the model saw the attachment, that the next turn's history still carries
it, and that oversized attachments are refused. The Actions fixture types `@` into the chat
editor, checks that the picker opens, presses Return, and checks that the clipboard item is
attached and the `@` removed without sending. Not verified: a live prompt with attachments
against a real provider.
