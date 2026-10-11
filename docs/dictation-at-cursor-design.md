# Dictation typed at the cursor — design

Design only, October 11, 2026. Nothing here is implemented except the non-key hotkey indicator
and the temporary Escape key, described under "Hotkey indicator (implemented)". It extends the shipped dictation
(`Volant/Dictation/SpeechDictation.swift`, `docs/ai-connections.md`), which copies the transcript
and leaves Command-V to the owner. The owner has decided to add an Accessibility helper and asked
whether it can run only for people who turn the feature on.

Labels used below: **Verified** means an Apple document, an Apple engineer's forum post, source
code read for this review, or a measurement already recorded in this repository. **Unverified**
means a community report, a vendor's help page, or reasoning that still needs a measurement. Every
unverified claim that the design depends on is listed under Phase 0.

## Summary and recommendation

- Put every Accessibility use in a new embedded XPC service, `VolantInputHost`
  (`com.mysticcoders.volant.InputHost`). Like `VolantAgentHost` it is not sandboxed, and it has a
  narrow API that only accepts a transcript the app has just produced. The main app stays
  sandboxed, with no network access and no Accessibility code.
- **Can the helper run only for people who want it? Yes.** An embedded XPC service is not a login
  item and is not registered anywhere. launchd starts it only when the app first sends it a
  message, and it exits when the app drops the connection. Until the setting is on, Volant never
  connects, so the helper never runs and nothing calls a TCC API that could prompt or add a
  Privacy entry. One limitation: macOS has no API that lets Volant remove its own Accessibility
  grant, so turning the feature off stops the helper but leaves the grant for the owner to remove.
- Insert text with a synthesized paste, which is the most compatible method. The helper writes the
  transcript to the pasteboard with the `org.nspasteboard` transient and concealed markers, posts
  Command-V and restores the previous clipboard. It refuses whenever secure input is on or a
  password field has focus, and in that case the transcript is copied as it is today.
- Expected attribution, still to be measured in Phase 0: TCC charges a bundled XPC service's checks
  to its container app, so the Privacy list says **"Volant"**, not "VolantInputHost". If Phase 0
  shows something else, the fallback is a bundled helper app registered with
  `SMAppService.loginItem` that shows its own entry, "Volant Input".
- Phases: 0, a spike in the Tart VM that measures TCC attribution. 1, insert at the cursor with the
  existing Carbon hotkey. 2, Globe or single-modifier triggers, plus Return to finish and Escape to
  cancel. 3, smart spacing and capitalization from the few characters before the cursor.

## What the platform allows (evidence)

| Question | Answer | Status and source |
| --- | --- | --- |
| Can a sandboxed app use the Accessibility APIs? | No. "It's not possible for a sandboxed app to use the Accessibility privilege" (without temporary exceptions). A second DTS reply says sandboxed apps are not supported even when `AXIsProcessTrusted` returns true | Verified: DTS, [thread 780626](https://developer.apple.com/forums/thread/780626), [thread 794253](https://developer.apple.com/forums/thread/794253) |
| Can a sandboxed app use Input Monitoring (a listen-only `CGEventTap`)? | Yes. DTS says "I regularly test this" | Verified: [thread 780626](https://developer.apple.com/forums/thread/780626) |
| Does an embedded XPC service share its container app's TCC grants? | It "should share the TCC privileges of the container app … this works well for XPC Services". The same post says it "doesn't work for … Service Management login items" | Verified for a `CGEventTap` on macOS 12 (DTS, [thread 706187](https://developer.apple.com/forums/thread/706187)). **Unverified** for an unsandboxed service inside a *sandboxed* container, for Accessibility specifically, and on macOS 26/27 |
| Which name do TCC prompts show for an XPC service? | "you want the TCC alert to show the app name, not the name of the XPC service". Responsibility is set up by the system; there is no API to control it | Verified as the design intent (DTS, [thread 731504](https://developer.apple.com/forums/thread/731504)); the list entry is unmeasured |
| How does TCC identify the app? | By the designated requirement in the code signature. Apps whose requirements match each other share access to privacy-protected resources | Verified: [TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements) |
| Does an update reset the grant? | Not if the designated requirement is unchanged (same identifier and Developer ID team). Grants are lost when the signing identity changes, and ad-hoc signatures are tied to the cdhash | Requirement-based identity is verified ([TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements); identity change: [thread 785384](https://developer.apple.com/forums/thread/785384)). Grants surviving a Sparkle update are **unverified** for Volant, and some vendors still tell users to re-grant after updates ([Rectangle](https://sites.google.com/view/rectangle-app/rectangle-not-working-macos-update)) |
| Which permission does an event tap need? | A listen-only tap needs Input Monitoring (`CGPreflightListenEventAccess`, macOS 10.15+). A tap that filters events, and posting events (`CGPreflightPostEventAccess`), need Accessibility | Preflight and request APIs verified in Apple's reference ([listen](https://developer.apple.com/documentation/coregraphics/cgpreflightlisteneventaccess()), [post](https://developer.apple.com/documentation/coregraphics/cgpreflightposteventaccess())). That a default tap maps to Accessibility, and that Accessibility also covers listening, are **community reports** ([thread 122492](https://developer.apple.com/forums/thread/122492)) |
| Unicode keystrokes | `CGEventKeyboardSetUnicodeString`: "application frameworks may ignore the Unicode string … and do their own translation based on the virtual keycode" | Verified: [Apple reference](https://developer.apple.com/documentation/coregraphics/cgevent/keyboardsetunicodestring(stringlength:unicodestring:)) |
| Secure input | `EnableSecureEventInput` keeps password-field keystrokes away from event taps. `IsSecureEventInputEnabled` reports whether secure input is on anywhere in the system | Verified: [TN2150](https://developer.apple.com/library/mac/technotes/tn2150/_index.html) |
| SMAppService agents and login items | Agents need a plist in `Contents/Library/LaunchAgents`. Registration shows the system's background-item notification and an entry in Login Items & Extensions | API verified: [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice), [agent(plistName:)](https://developer.apple.com/documentation/servicemanagement/smappservice/agent(plistname:)). The notification is a secondary source ([Kandji](https://support.kandji.io/support/solutions/articles/72000578621)) |
| Repository precedent | An unsandboxed XPC service inside a sandboxed, Developer ID signed app keeps the privilege the app lacks. Measured for `kill`. The code-signing requirement on callers held up when tested by attacking it | Verified: `docs/process-control-spike.md` ("Follow-up", September 20, 2026). TCC was **not** part of that spike |

## Process model options

| | A. Embedded XPC service (recommended) | B. `SMAppService.agent` launch agent | C. Bundled helper app (`SMAppService.loginItem`, or launched with `NSWorkspace`) |
| --- | --- | --- | --- |
| Name in Privacy & Security | "Volant", expected by design intent. **Unverified** | The agent's own identity, for a bare executable often its path or name. **Unverified** | The helper's own name and icon, for example "Volant Input". **Unverified** |
| Who holds the grant | Volant's designated requirement. The sandbox stops the main app from using Accessibility. A listen-only tap would technically be allowed there, so a code rule, not the OS, keeps the main app from creating one | The agent | The helper app |
| Dormant until enabled | Yes. Starts on first connection, no registration | Registered on enable, launched on demand through `MachServices`, unregistered on disable | Registered or launched on enable, quit on disable |
| System UI side effects | None | Background-item notification and a Login Items entry | Same as B for `loginItem`. None for an `NSWorkspace` launch, but the helper then cannot vend a Mach service without launchd |
| IPC from a sandboxed app | Private to the bundle (`NSXPCConnection(serviceName:)`), already used four times | Needs an app-group-prefixed Mach service name and the application-groups entitlement | Same as B |
| Lifetime | Ends with the app, and launchd can stop it when idle | Independent of the app | Independent of the app |
| Packaging | `Contents/XPCServices`, same as `VolantAgentHost`. Hardened runtime, no special entitlements | New plist, new target, app-group entitlement | New app target and its own icon |
| Sparkle | Replaced with the app. The grant follows Volant's requirement | Replaced with the app. Sparkle must not unregister it | Same as B |

**Recommendation: A.** It is the only option that is dormant without registering anything. It uses
the IPC and signing pattern Volant already has, and it produces no background-item notification.
Raycast also isolates Accessibility in a separate XPC service, `com.raycast.macos.Accessibility`
(`docs/competitors.md`). The privacy entry reading "Volant" is the honest name: the owner is
trusting Volant's signed code, and the disclosure must say so (see "Privacy and marketing").

If Phase 0 shows that a sandboxed container cannot pass an Accessibility grant to an unsandboxed
service, or that the entry is unusable, switch to **C with `SMAppService.loginItem`**. It gives a
separately named entry at the cost of a Login Items entry and app-group IPC. B adds nothing over C
for a GUI-session feature.

## On-demand lifecycle

Setting: Settings → General → Dictation → **Type into the focused app** (`dictationTypesAtCursor`,
default off). It applies to this Mac only, stays out of `SettingsSync.keys` and is patched through
`Preferences.updateBoolean`, like `dictationLowersVolume`.

1. **Off (default).** No connection to `VolantInputHost`, so the helper is not running and no TCC
   call has been made. Dictation copies, as today.
2. **Turned on.** The app connects and calls `status()`. The helper answers with
   `AXIsProcessTrustedWithOptions` with prompt false, which never prompts or adds a list entry
   (unverified for XPC), and `IsSecureEventInputEnabled()`. Settings shows "Accessibility: Not
   allowed" with a **Grant Access** button.
3. **Grant Access** (an explicit click). The helper calls `AXIsProcessTrustedWithOptions` with prompt
   true once. This adds the entry and shows the system alert. The app also opens Privacy &
   Security → Accessibility through
   `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`. That URL is not
   documented by Apple and is widely used, so it is unverified. If it fails to open, the fallback is
   the Privacy & Security pane.
4. **Return from Settings.** On app activation the app *invalidates* the helper connection and
   reconnects before calling `status()` again. DTS advises making sure the XPC service terminates
   when the setting changes ([thread 706187](https://developer.apple.com/forums/thread/706187)), and
   some trust checks reportedly do not update in a running process. A fresh process avoids stale
   answers.
5. **Use.** Phase 1 connects at dictation start and lets the connection idle afterwards. Phase 2
   keeps the connection open while a Globe or modifier trigger is configured, because the tap lives
   in the helper.
6. **Turned off.** The app removes taps, invalidates the connection, and the helper exits when its
   only client is gone (`exit(0)` from the invalidation handler). The grant remains. Settings says:
   "Volant no longer uses Accessibility. To remove its access, turn off Volant in Privacy &
   Security → Accessibility." It also offers **Open Accessibility Settings**. Volant never runs
   `tccutil` and cannot revoke the grant itself.
7. **Turned on again.** The helper starts, `status()` reports the existing grant, and nothing
   prompts.
8. **Grant revoked while on.** The helper checks trust before every insertion and every 5 seconds
   while a tap exists. On revocation it removes the tap at once (see Risks) and reports
   `.notTrusted`, and dictation goes back to copying.

## Insertion strategy

Order of attempts, all inside the helper:

1. **Refuse** if `IsSecureEventInputEnabled()` is true, the focused element's role or subrole is
   `AXSecureTextField`, there is no focused element, or the frontmost app's pid or launch date
   differs from the one recorded when dictation started. The app then copies the transcript and
   gives the reason, for example "A password field is active. Copied instead." Terminal's Secure
   Keyboard Entry turns on secure input, so Terminal is refused while it is enabled. This is
   intended behavior.
2. **Synthesized paste (primary).**
   - Snapshot every item and type on the general pasteboard. If the snapshot exceeds 32 MB, or
     contains types whose data cannot be read eagerly (file promises), skip the restore and say
     that the clipboard now holds the transcript.
   - Write one item: the text as `public.utf8-plain-text`, plus `org.nspasteboard.TransientType`,
     `org.nspasteboard.ConcealedType` and a private `com.mysticcoders.volant.dictation-session`
     type carrying a random ID. Volant's own `PasteboardFilter` already refuses all three marker
     families, so dictation never enters encrypted clipboard history. Other managers that follow
     [nspasteboard.org](http://nspasteboard.org) skip it too.
   - Wait 100 ms. Post Command-V with key codes `0x37` and `0x09` from a `privateState` event source
     to `cghidEventTap`. Using physical key codes avoids layouts that remap when Command is held.
   - After at least 250 ms, restore the snapshot, but only if `changeCount` and the session marker
     show the pasteboard still holds this write. If the owner copied something in between, it is
     never overwritten.
   - This is VoiceInk's approach: `CursorPaster.swift` uses a 100 ms delay before paste and at least
     250 ms before restore, and `ClipboardManager.swift` uses a session marker and the transient
     marker. Source read at commit `c09cc1f`; VoiceInk is GPL, so take the approach and none of the
     code. Superwhisper documents that it needs Accessibility "for pasting into other apps"
     ([quickstart](https://superwhisper.com/docs/get-started/quickstart)).
3. **Unicode keystrokes (fallback, opt-in per app later).** Use only for apps known to block paste.
   Frameworks may ignore the string (Apple reference above). Typing is slow, triggers autocomplete
   and input methods, and some apps record every event as its own undo step. Not part of Phase 1.
4. **Not used for insertion: setting the AX selected-text attribute.** It works in native Cocoa
   text views. Chromium and Electron expose a full tree only after `AXManualAccessibility` is set
   ([Electron docs](https://www.electronjs.org/docs/latest/tutorial/accessibility)), web editors may
   not fire their input events, and undo support varies. Paste behaves the same as the owner's own
   Command-V everywhere, including terminals, where bracketed paste stops a multi-line transcript
   from running as commands. Unverified: test per terminal.

Text policy: at most 20,000 UTF-16 units. C0 control characters other than `\n` and `\t` are
removed. Nothing else is changed in Phases 1 and 2.

Behavior by surface, all to be measured in Phase 1: native Cocoa, Safari or Chrome text areas and
`contenteditable` editors, Electron (Slack, VS Code), Terminal, iTerm2 and Ghostty, and Microsoft
Office. Undo after a paste should be a single step. This is unverified for each app.

**Focus.** The hotkey used to show the launcher (`showForDictation()`), which made it the key
window, so a posted Command-V would have landed in Volant's own search field. Hotkey dictation now
shows the non-key indicator described under "Hotkey indicator (implemented)" instead, and focus
stays in the target app throughout. Insert mode reuses that indicator.

## Hotkey indicator (implemented)

Implemented October 11, 2026, ahead of the Accessibility helper, because it is useful on its own:
the Dictate Text hotkey no longer shows the launcher. Dictation started with `talk` inside the
launcher keeps its in-launcher status line.

- **Window.** `DictationIndicatorPanel` (`Volant/Dictation/DictationIndicatorPanel.swift`) is a
  borderless `.nonactivatingPanel` whose `canBecomeKey` and `canBecomeMain` are false. It ignores
  the mouse, sits at `.statusBar` level, joins all Spaces and full-screen apps
  (`.canJoinAllSpaces`, `.fullScreenAuxiliary`, `.stationary`, `.ignoresCycle`) and is shown with
  `orderFrontRegardless`. Nothing on this path calls `makeKey`, `NSApp.activate` or the launcher, so
  the frontmost app keeps focus. It appears 72 points above the bottom of the visible frame of the
  screen under the pointer, or the main screen, and is drawn on the theme's window background with
  a separator border so light, dark and palette themes stay legible in a window that is never key.
  There is no click target: a Cancel button would need mouse events, and Escape and the hotkey
  already cover stopping.
- **States.** `DictationIndicatorModel` (`Volant/Dictation/DictationIndicator.swift`): Listening,
  with the stop hint ("Release or press ⌥Space to stop. Escape cancels."), then the live
  transcript, then Transcribing… while the analyzer finishes, then a result that hides after two
  seconds and fades over a quarter second: "Copied N characters — press ⌘V to paste.", "Nothing was
  heard.", "Dictation cancelled.", or the failure's reason. A volume problem from
  `DictationVolumeDuck` is shown while dictation runs and appended to the result; one that arrives
  after the result extends it. A recognition failure while listening, which has no completion
  callback, is reported from the phase change so the indicator never stays on Listening.
- **Live text.** `SpeechDictation.transcript` already carried settled plus volatile results. The
  indicator keeps only its last 120 characters, cut at a word boundary with a leading ellipsis. It is
  held in memory, never logged or persisted, and cleared when the result shows.
- **Escape.** While the indicator is listening, `DictationEscapeKey` registers unmodified Escape
  (`kVK_Escape`, no modifiers) through `HotKeyCenter`, and unregisters it the moment the indicator
  leaves Listening, whether dictation finished, was cancelled or failed, and before hotkeys are
  re-registered after a settings change. Carbon hotkeys need no Accessibility or Input Monitoring
  grant. `RegisterEventHotKey` returned `noErr` for unmodified Escape on macOS 27 in an unsigned,
  unsandboxed probe that registered and immediately unregistered it; delivery of a real keypress to
  the signed, sandboxed app is not yet measured. While registered, Escape is consumed system-wide,
  so the frontmost app does not see it for those seconds. If registration fails, for example
  because another app holds Escape, the hint leaves Escape out and the dictation hotkey still stops.
  Escape held together with the hotkey's modifiers does not match the unmodified registration.
- **Clipboard.** Unchanged: the transcript is copied exactly as before, and nothing is typed.
- **Evidence.** `VolantTests/DictationIndicatorTests` covers the state machine with an injected
  clock (listening, partial text, transcribing, result, hidden; cancel; failure; volume problems
  during and after a result; a new dictation cancelling an old hide; the 120-character bound) and
  the Escape registration lifecycle with injected register and unregister closures.
  `tools/check-dictation-hud.sh` compiles the production indicator view and panel, shows it while
  the process is in the background and then over another key window, and asserts that no Volant
  window becomes key or main, the other window keeps key status and first responder, and a
  background process is not activated. It writes
  `/tmp/volant-launcher-dictation-hud-<state>-<light|dark>.jpg` for `listening`, `partial`,
  `transcribing`, `copied`, `failed-volume` and `cancelled`, collected by the Tart UI run. The
  fixture never registers a hotkey or starts the microphone. Real hotkey and Escape delivery,
  full-screen Spaces placement and live recognition in the signed installed app are separate
  evidence.

## Trigger keys

- **Phase 1:** the existing Carbon `talkHotKey`, hold or tap, unchanged. Escape cannot reach a
  panel that is not key, so the hotkey indicator already registers unmodified Escape with
  `RegisterEventHotKey` only while it is listening (see "Hotkey indicator (implemented)"). Delivery
  of that Escape to the signed, sandboxed app still needs Phase 0's measurement.
- **Phase 2: Globe (fn) or a single modifier** (left or right Option, Command or Control) as the
  hold-to-talk trigger. Carbon cannot register a modifier on its own, so the helper runs a tap.
  - Base tap: `CGEvent.tapCreate(tap: .cgSessionEventTap, …, eventsOfInterest: flagsChanged only)`.
    It reads the key code (`kVK_Function` 63, `kVK_RightOption` 61, and so on) and modifier flags,
    nothing else.
  - A transient key tap exists only while the trigger is held or dictation is active, and is
    removed when it ends. It detects chording (the owner held Option to type Option-arrow, so do not
    start) and, while dictating, consumes Return to finish and Escape to cancel. The callback
    examines only "a key was pressed" and the codes for Return and Escape. It stores, logs and
    forwards nothing else. Outside those windows the helper sees no keystrokes.
  - Consuming Return or Escape needs a filtering tap and therefore Accessibility, which the helper
    already has. It is not known whether that one grant also covers listening without a separate
    Input Monitoring entry. If Phase 0 shows that Input Monitoring is also required, Settings
    explains both.
  - Handle `tapDisabledByTimeout` and `tapDisabledByUserInput` by re-enabling the tap and resetting
    the held state. The callback only flips state and posts to a queue.
  - **Globe conflicts.** macOS's "Press 🌐 key to" setting (Change Input Source, Show Emoji &
    Symbols, Start Dictation, Do Nothing) keeps acting on the key
    ([Apple Dictation help](https://support.apple.com/guide/mac-help/use-dictation-mh40584/mac)).
    Wispr Flow tells users to set it to Do Nothing
    ([Wispr docs](https://docs.wisprflow.ai/troubleshooting/shortcuts)). Volant does the same. The
    helper does not try to suppress Globe, because whether a tap *can* suppress the system's Globe
    action is unverified. The setting cannot be changed from the sandbox, so Settings shows the
    instruction when Globe is chosen. External keyboards may not send fn at all (Wispr docs).
    Superwhisper lets users pick Left or Right Command or Fn alone
    ([shortcuts](https://superwhisper.com/docs/get-started/settings-shortcuts)), and VoiceInk's
    `ShortcutMonitor.swift` uses a session tap with `.defaultTap` over `flagsChanged`, key and mouse
    events.
  - Behavior matches `talkHotKey`: held for more than 0.4 s, release finishes; a tap toggles.
  - The helper sends the app events only: `triggerDown`, `triggerUp`, `finishRequested`,
    `cancelRequested`. It never sends key codes or characters.

## Context reading for smart spacing (Phase 3)

The helper reads the few characters before the cursor and keeps them to itself:

1. Read `kAXFocusedUIElementAttribute` from the system-wide element. Stop if the role or subrole is
   secure, or if secure input is on.
2. Read `kAXSelectedTextRangeAttribute` (a `CFRange`). Read **at most 8 UTF-16 units** before
   `location` with `kAXStringForRangeParameterizedAttribute`, never the whole `kAXValueAttribute`.
   If the parameterized attribute is unsupported, do not fall back to reading the full value. Use
   no context.
3. Pass the characters and the transcript to `DictationSpacing.adjust(transcript:preceding:)`, a
   pure function in VolantCore. It adds a leading space after a word character, adds none after an
   opening bracket, a newline or a space, and lowercases the first letter mid-sentence. It
   capitalizes after `.`, `!` or `?`, at the start of the field, or when no context is available.
4. Throw the context away. It never leaves the helper, never goes into logs, crash annotations or
   `os_log` (not even as private), and is never stored. The adjusted text is not returned to the
   app either. The result says only whether an insertion happened.

Chromium and Electron may need `AXManualAccessibility` before step 2 works. Setting it changes the
target app's accessibility mode and performance, so Phase 3 does not set it. Those apps get
neutral spacing.

## XPC API sketch

Method signatures only. The service authenticates callers with
`NSXPCConnection.setCodeSigningRequirement` (macOS 13+), using
`anchor apple generic and identifier "com.mysticcoders.volant" and certificate leaf[subject.OU] = "REMBT6JY4N"`.
This replaces `VolantAgentHost`'s pid-based `SecCodeCopyGuestWithAttributes` check, which can race
against pid reuse. Payloads are small Codable values in `Data`, validated on both sides.

```swift
@objc protocol VolantInputHostProtocol {
    func status(reply: @escaping (Data) -> Void)                  // InputHostStatus: trusted, secureInput; never prompts
    func requestAccessibility(reply: @escaping (Data) -> Void)    // prompt=true; only from an explicit Settings click
    func beginSession(reply: @escaping (Data) -> Void)            // records frontmost pid, launch date, bundle ID; returns a 32-byte token or a refusal
    func insert(text: String, token: Data, reply: @escaping (Data) -> Void)   // InsertResult: inserted, refused(reason), failed
    func endSession(token: Data)
    func startTrigger(_ trigger: Data, reply: @escaping (Data) -> Void)       // Phase 2: fn, or a named single modifier; no arbitrary key code
    func stopTrigger()
}

@objc protocol VolantInputClientProtocol {                        // exported by the app on the same connection
    func triggerDown(); func triggerUp(); func finishRequested(); func cancelRequested()
}
```

Rules enforced in the helper, not the app:

- One session at a time. A token is single-use, expires 120 s after `beginSession` (longer
  dictation can call `beginSession` again), and is bound to the recorded target.
- `insert` re-checks trust, secure input, secure field and target identity at the moment of use.
- No method accepts key codes, modifier flags, AX attribute names, element paths, pids or bundle
  IDs. No method returns text from another app. There is no "type this anywhere" or "read that"
  entry point.
- The token does not prove the text came from speech. It limits a compromised or confused caller to
  one paste into the app the owner was already using, during dictation the owner started. That is
  no more than the owner's own Command-V. The signing requirement keeps every other process out.

## Permissions UX copy

- Setting label: "Type into the focused app".
- Setting help: "Dictation types its final text where your cursor is, instead of copying it. Needs
  Accessibility permission, used only by Volant's input helper and only to paste text and, with
  smart spacing, to read up to 8 characters before the cursor. Passwords and secure fields are
  never typed into."
- Status rows: "Accessibility: Allowed" / "Accessibility: Not allowed — Grant Access" /
  "Unavailable: needs macOS 26 or later".
- After Grant Access: "In Privacy & Security → Accessibility, turn on Volant, then come back here."
- Fallback messages after dictation: "Typed 42 characters." / "A password field or secure input is
  active. Copied instead." / "The focused app changed. Copied instead." / "Accessibility is off.
  Copied instead."
- Globe help: "Set Keyboard → Press 🌐 key to → Do Nothing, or macOS will also act on the key."
- Turned off: "Volant no longer uses Accessibility. To remove its access, turn off Volant in
  Privacy & Security → Accessibility." with Open Accessibility Settings.

## Privacy and marketing changes

The current claims become false for owners who turn this on: "no Accessibility or Input Monitoring
grant" in `docs/competitors.md`, `docs/cross-platform-core.md` and the website, and the comment on
`LauncherModel.toggleDictation`. When this ships:

- `docs/marketing-claims.md`, the website and the README say: "Volant's main app is sandboxed
  and never uses Accessibility. If you turn on Type into the focused app, a separate helper inside
  Volant gets Accessibility permission (listed as Volant in System Settings) so it can paste your
  dictation. It cannot read or type anything else, and it does not run unless that setting is on."
  If Phase 2 needs Input Monitoring, say so too.
- Keep "no Accessibility by default" as the claim, never "no Accessibility".
- Add a "Helpers" disclosure listing all five XPC services, which ones are unsandboxed (Agent,
  Input) and why. `docs/process-control-spike.md` already asks for this.
- Add an Info.plist usage line only if Phase 0 shows that a prompt displays one. Accessibility
  prompts normally have no purpose string. Unverified.

## Testing plan

**Unit fixtures, no grants, safe on CI and the owner's Mac:**

- `DictationSpacing` in Core: a table of preceding contexts against transcripts, including emoji,
  combining marks and right-to-left text across UTF-16 boundaries.
- Text policy: length cap and removal of control characters.
- Session and token state machine with an injected clock: single use, expiry, target mismatch,
  secure input and secure field refusals, a revoked grant mid-session.
- Pasteboard save, write and restore against a *private named* `NSPasteboard`, never `.general`:
  marker types present, no restore after an interleaved copy, oversize and promise cases skip the
  restore.
- Trigger state machine fed synthetic `flagsChanged` and key sequences: hold, tap, chorded
  modifier, tap disabled by timeout, Return and Escape only while dictating. No real tap is
  created.
- Settings model: setting off means no connection is made. Assert that the client factory is never
  called.
- `PreferencesTests` for the new key's default and narrow patch.
- Unit-test hosts must not create an event tap, connect to the helper or touch the general
  pasteboard (AGENTS.md).

**Signed, installed-app evidence the owner must run (not provable by fixtures or hosted CI):**

1. Phase 0 spike in a fresh Tart guest, extending `tools/spike-privaccess.sh`: a sandboxed fixture
   app with an embedded unsandboxed XPC service, both Developer ID signed with deployment target
   15.0. Record:
   - the Privacy list name and icon, and the prompt text;
   - whether the service's `AXIsProcessTrusted` turns true after granting "Volant";
   - whether the sandboxed app's own `AXIsProcessTrusted` also reads true;
   - Command-V delivery to TextEdit;
   - whether a filtering tap works without an Input Monitoring entry;
   - whether Escape and Return can be registered with Carbon and no modifiers;
   - whether status with prompt false leaves no list entry;
   - grant persistence across a re-signed build with a bumped `CFBundleVersion`, and across a real
     Sparkle update between two signed builds;
   - removing the grant while a tap is active.
   Repeat for option C if A fails.
2. Installed `/Applications/Volant.app`: enable the setting, grant access, then dictate into
   TextEdit, Notes, Safari and Chrome text areas, an Electron app, Terminal, iTerm2 and Ghostty,
   and a password field (it must refuse). Repeat with Terminal Secure Keyboard Entry on (it must
   refuse). Check that the previous clipboard contents (text, an image, a Finder file) come back,
   and that clipboard history has no dictation entry.
3. Disable, confirm that no `VolantInputHost` process is running, re-enable with no prompt, then
   revoke in System Settings with the feature on.
4. Phase 2 on the owner's MacBook keyboard and an external keyboard: Globe set to Do Nothing and to
   Show Emoji, a right-Option trigger, and Option-arrow chording without starting dictation.
5. Light and dark renders of the Settings rows from compiled fixtures (the indicator's renders
   already exist, see "Hotkey indicator (implemented)").
   Live permission flows are separate evidence.

Host UI runs need an agreed window with the owner. Routine checks run in the VM.

## Risks and open questions

- **Attribution inside a sandboxed container is unmeasured.** The whole recommendation depends on
  Phase 0. DTS's confirmation is from macOS 12 and covers a tap, not Accessibility.
- **The grant belongs to "Volant", not only the helper.** If TCC attributes to the container, a
  future change in the main app could create a listen-only tap under the owner's grant. The
  sandbox still blocks Accessibility. Mitigations: a lint or check that `CGEvent.tapCreate`,
  `AXUIElement` and `CGEventPost` appear only in `VolantInputHost/`, and saying this in the
  disclosure.
- **Input can freeze if Accessibility is revoked while a tap is active** (community report,
  [thread 844416](https://developer.apple.com/forums/thread/844416)). Mitigations: the transient key
  tap, polling trust, and removing the tap on revocation. Test in the VM before Phase 2 ships.
- **Clipboard races.** Slow apps may read the pasteboard after it has been restored and paste the
  old contents. Lazy and promised data cannot be fully restored. The restore delay may need to
  depend on the app, and rare cases fall back to leaving the transcript on the clipboard and
  saying so.
- **Grant loss after updates or OS upgrades.** Expected not to happen with a stable designated
  requirement, but there are field reports. Volant detects it on every use and falls back to
  copying with a clear message.
- **Globe behavior** is controlled by macOS and differs by keyboard. Recommend a single modifier as
  the default trigger and offer Globe with its instruction.
- **The focus model changes.** Insert mode cannot use the key launcher panel. This touches
  `LauncherPanel` and the shown-while-listening rule in `docs/ai-connections.md`.
- **App Store.** Not applicable (Developer ID). Paste-by-event apps have been rejected under
  Guideline 2.4.5 ([thread 820594](https://developer.apple.com/forums/thread/820594)).
- **Open questions:**
  - Should a target that changed fall back to copying (proposed), or follow the new frontmost app?
  - Should smart spacing be on by default once Phase 3 ships?
  - Should the keystroke fallback exist at all?

## Phased implementation plan

0. **Spike** (no product code): the VM measurements listed in Testing plan step 1. Outcome:
   choose A or C, the exact Settings copy for the list name, and whether Input Monitoring or the
   Carbon Escape key is needed.
1. **Insert at the cursor with the existing hotkey.**
   - New `VolantInputHost` target: embedded XPC service, hardened runtime, no sandbox,
     `JoinExistingSession` and `RunLoopType = NSRunLoop` in its `XPCService` dictionary.
   - `status`, `requestAccessibility`, `beginSession`, `insert` and `endSession`.
   - Paste with markers and restore, plus the secure-input and secure-field refusals.
   - Settings toggle and permission rows. The non-key indicator and Carbon Escape already exist.
   - Fallback to copying with a reason; the CI check confining Accessibility APIs to the helper.
   - Documentation and marketing updates.
2. **Globe or single-modifier trigger, plus Return and Escape.** The helper's `flagsChanged` tap, the
   transient key tap, client callbacks, Settings trigger picker with Globe help, and handling of a
   disabled tap or revoked grant.
3. **Smart spacing.** `DictationSpacing` in Core, the bounded context read through the
   parameterized range attribute, and a toggle under the main setting.

Each phase follows the AGENTS.md delivery workflow. `tools/test-scope.py` must learn the new helper
and the dictation UI surfaces.
