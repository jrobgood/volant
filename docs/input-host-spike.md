# Input host spike: TCC attribution and insertion (Phase 0)

October 11, 2026. This is Phase 0 of [dictation typed at the cursor](dictation-at-cursor-design.md):
measurements only, no product code. The spike sources in `tools/input-spike/` are not shipped, are
not in any app target, and exist only to answer the design's unverified points. Everything below ran
in disposable Tart guests. Nothing ran on the owner's Mac, and the owner's TCC database was never
read or changed.

## Owner decisions folded in

- Dictation output becomes a setting: **Copy to clipboard** (default, today's behavior, no helper)
  or **Type at the cursor** (needs the helper; choosing it leads to the one-time Accessibility
  request). With typing on, a sub-option types **while speaking** (each finalized phrase as it
  arrives) or **when finished**.
- Volant must never become frontmost during dictation. A non-activating indicator is being built
  separately.
- Live typing prefers direct AX insertion (setting `kAXSelectedTextAttribute` on the focused
  element) per finalized phrase, with synthesized paste only as a fallback.

The spike therefore measured live, phrase-by-phrase insertion (three phrases 0.4 s apart) for every
method, checked that the target app stayed frontmost throughout, and measured how to detect a
failed AX insertion.

## Setup

| | |
| --- | --- |
| Main guest | Disposable clone of `volant-ui-xcode`: macOS 15.7.7 (24G720), Xcode 16.4 installed but unused, SIP disabled in the image, 4 cores, 8 GB. Deleted after the run |
| Second guest | Disposable clone of `volant-render-27`: macOS 27.0 (26A428), SIP enabled, no developer tools. Used only for questions 1 and 2. Deleted after the run |
| Host build | macOS 27.0.1 (26A434), Xcode 27.1, Swift 6.4, `-target arm64-apple-macosx15.0` |
| Signing | **Developer ID Application: Mystic Coders, LLC (REMBT6JY4N)**, hardened runtime, secure timestamp, not notarized (`spctl` says "Unnotarized Developer ID"; it runs because the copies carry no quarantine). An **ad-hoc** pair was built as the contrast for question 3 |
| Container | `Input Spike.app`, `com.mysticcoders.volant.inputspike`, `LSUIElement`, App Sandbox entitlement only, accessory activation policy, never activates |
| Service | `Contents/XPCServices/VolantInputHost.xpc`, `com.mysticcoders.volant.inputspike.InputHost`, no entitlements (unsandboxed, like `VolantAgentHost`), `ServiceType` Application, `JoinExistingSession`, `RunLoopType` NSRunLoop; requires callers signed by the same team |
| Launch | `open -g -n -W` through LaunchServices, so the container is its own responsible process. Started from the guest agent directly, it would inherit the agent's own Accessibility grant and prove nothing |

The service reports `responsibility_get_pid_responsible_for_pid` (a private call, used only as a
diagnostic) for itself: in every run its responsible process was the container, never the guest
agent.

### How the grant was given

The image grants Accessibility to `sshd-keygen-wrapper` and `osascript`, so a script over SSH can
drive System Settings with AppleScript UI scripting. `tools/input-spike/guest/grant.sh` opens
Privacy & Security → Accessibility, clicks the "Input Spike" switch, and answers the password sheet
that appears. Synthesized keystrokes into that sheet were ignored, so it sets the secure field's AX
value and clicks **Modify Settings**. TCC then recorded the grant itself (`auth_value` 2). No
TCC.db row was written by hand, and the SIP-disabled image was used only to read TCC.db.

Not exercised: clicking **Open System Settings** in the prompt itself, and any grant on macOS 27
(its image does not grant UI scripting, and SIP blocks the database).

### Reproduce

```sh
tools/input-spike/run-vm.py --with-host-apps
```

It builds the four bundles, clones `volant-ui-xcode` (refusing if any local VM is running), runs
`guest/phase1-before-grant.sh`, `guest/grant.sh`, `guest/phase2-after-grant.sh` and the ad-hoc
steps in `guest/phase3-adhoc.sh`, then stops and deletes the clone. `--with-host-apps` copies the
host's installed Google Chrome and Obsidian bundles into the guest; nothing is downloaded. The log
and screenshots stay in the printed temporary directory.

The macOS 15.7.7 results were first gathered step by step, then reproduced end to end with this
runner. The first runner attempt failed to give the grant (System Settings had not finished loading
its list when the switch was clicked), so `grant.sh` now retries until the password sheet appears;
the second attempt reproduced every result below. The macOS 27.0 checks were run by hand over SSH
in a disposable clone of `volant-render-27` and are not part of the runner.

`tccd`'s log in that run attributed 15 requests to the service process and charged all of them,
like the container's own, to `com.mysticcoders.volant.inputspike`. No check was charged to
`com.mysticcoders.volant.inputspike.InputHost`. A first tccd write can lag the call by a few
seconds, so the scripts wait before reading TCC.db.

## Results

| # | Question | Result | Status |
| --- | --- | --- | --- |
| 1 | Name in the Accessibility prompt and list | Container: "“Input Spike” would like to control this computer using accessibility features." List entry "Input Spike". No purpose string | **Verified** (15.7.7). On 27.0 the TCC row is the container's; the prompt was not visible to the harness |
| 1 | Identity tccd checks | `AUTHREQ_SUBJECT=com.mysticcoders.volant.inputspike` for every check the service made | **Verified** (15.7.7 and 27.0) |
| 1 | Granting the container makes the service trusted | Service: `AXIsProcessTrusted` true, post preflight true, listen preflight true | **Verified** (15.7.7) |
| 1 | Sandboxed container reads trusted | Yes, all three preflights true. Its AX calls fail with `kAXErrorCannotComplete` (-25204), but a listen-only tap is created | **Verified** (15.7.7) |
| 1 | Input Monitoring | Not needed: with only Accessibility, the service's listen-only and filtering session taps were created and each saw the probe key. `CGRequestListenEventAccess` showed no prompt and added no entry on 15.7.7 (tccd: denied, reason "system set"); on 27.0 one request added a denied Input Monitoring row for the container, and a repeat after reset did not | Taps **verified** (15.7.7). An Input Monitoring prompt or grant **not exercised** |
| 2 | Prompt-free status adds an entry | **Yes on 15.7.7**: the service's prompt-false check added a denied row and a visible "Input Spike" entry with its switch off. The container's own prompt-false check added nothing. **No on 27.0** | **Verified** on both |
| 3 | Update with the same Developer ID identity | Build 1 → build 2, fresh bundle swap, new cdhash: still trusted, same TCC row and requirement | **Verified** (15.7.7). Real Sparkle run, notarized builds, OS upgrade **not exercised** |
| 3 | Ad-hoc contrast | Ad-hoc build over the Developer ID grant: not trusted. Ad-hoc build 1 granted → ad-hoc build 2: not trusted, while the switch still shows on | **Verified** (15.7.7) |
| 4 | Insertion | See the table below | **Verified** for the apps listed (15.7.7) |
| 4 | Secure input blocks injection | **No.** Paste and Unicode keystrokes typed into password fields in Chrome (secure input on) and Safari (secure input off) | **Verified** (15.7.7) |
| 5 | Carbon bare Escape and Return | `RegisterEventHotKey` with no modifiers returned `noErr` for both in the sandboxed container, the handler fired, and the frontmost app did not get them. After unregistering, Return reached the app | **Verified** with HID-posted events (15.7.7). Physical keyboard **not exercised** |

### Insertion, phrase by phrase

Three phrases ("Hello there.", " This is live dictation.", " Café 👍 done.") 0.4 s apart, then
Command-Z twice. Results were read back through the service's diagnostic AX read, from the page
(input-event counter and password length mirrored into the page), or from the note file on disk.
In every run the target stayed frontmost and the container never activated. Accented characters
and emoji arrived intact wherever text arrived.

| Target | AX `kAXSelectedTextAttribute` | Synthesized Command-V | `CGEventKeyboardSetUnicodeString` |
| --- | --- | --- | --- |
| TextEdit (plain-text `NSTextView`) | Inserted; character count 0 → 12 → 36 → 50, one step per phrase. One undo removed the whole dictation | Inserted; one undo per phrase | Inserted; undo grouped by pauses (two steps) |
| Terminal (zsh) | **Success code, nothing inserted.** Reports the attribute not settable | Inserted at the prompt | Inserted |
| Safari textarea (`file://`) | **Success code, nothing inserted, no input event**, although it reports the attribute settable | Inserted, 3 input events; one undo per phrase | Inserted, 49 input events; one undo removed all |
| Google Chrome 154 textarea | No focused element (`kAXErrorNoValue`) until the tree is turned on; then **success code, nothing inserted** | Inserted; one undo per phrase | Inserted; undo **per character** |
| Obsidian 1.12.7 (Electron) | No focused element until `AXManualAccessibility`; then **success code, nothing inserted** | Inserted; one undo per phrase | Inserted; one undo removed all |
| Safari password field (`AXSecureTextField`, secure input **off**) | Nothing inserted | **Inserted** (length 12) | **Inserted** (length 12) |
| Chrome password field (secure input **on**, no focused element) | No focused element | **Inserted** (length 12) | **Inserted** (length 12) |

Paste details: each phrase took about 415 ms (100 ms before Command-V, 300 ms before restore).
The clipboard held a sentinel string before each run and held it again afterwards in every app;
the marked write (`org.nspasteboard.TransientType`, `ConcealedType`, session marker) was restored
only when `changeCount` still matched.

**Detecting a failed AX insertion without reading text.** `kAXNumberOfCharactersAttribute` before
and after each set rose in TextEdit (0 → 12 → 36 → 50) and stayed flat in every no-op case (Terminal
101 → 101, Safari 0 → 0, Chrome 0 → 0, Obsidian 1 → 1). The settable flag is not a usable
predictor: Safari, Chrome and Obsidian report it settable and then ignore the write.

Also seen: System Settings' password sheet ignored synthesized keystrokes but accepted a value set
through AX. Neither OS mechanism can be relied on to keep text out of a secure field.

## Recommendation

**Confirm the embedded XPC design (option A).** The login-item fallback is not needed: the
container's grant reaches the unsandboxed embedded service, the list entry carries Volant's own
name, and a same-identity update keeps it. Changes the design needs:

1. **Copy.** The Privacy list and prompt will say "Volant". There is no purpose string to add.
2. **macOS 15 status checks add an entry.** Call `status()` only after the owner chooses Type at
   the cursor, which is already the plan, and do not claim that choosing it leaves no trace. On
   macOS 27 the prompt-free check left nothing.
3. **One permission.** Accessibility alone covers posting events and both kinds of tap, so Phase 2
   needs no Input Monitoring request.
4. **Enforce the confinement check.** The grant also lets the sandboxed main app create a
   listen-only tap. Keep `CGEvent.tapCreate`, `AXUIElement` and `CGEventPost` inside
   `VolantInputHost/` with a CI check, and say so in the disclosure.
5. **AX-first insertion needs verification.** Use AX per phrase as the owner prefers, but compare
   `kAXNumberOfCharactersAttribute` before and after each set; on no change, paste that phrase and
   stay on paste for the rest of the session in that app. Do not trust the settable flag or the
   returned error. Expect AX to succeed mainly in native Cocoa text views; elsewhere live typing
   will be paste per phrase (about 0.4 s and a clipboard write and restore each).
6. **Refusal must be the helper's own.** Refuse when the focused element's subrole is
   `AXSecureTextField` or `IsSecureEventInputEnabled()` is true. Chrome and Electron expose no
   focused element by default, so there only secure input is visible. Chrome turns it on for
   password fields; Electron was not tested.
7. **Escape and Return.** Register them through Carbon with no modifiers only while dictating, from
   the main app. No permission is needed.

## Not exercised

- Any grant, insertion or Carbon check on macOS 26 or 27. Only questions 1 and 2 ran on 27.0.
- A real Sparkle update between two signed, notarized builds, and an OS upgrade.
- Physical keyboard delivery for the Carbon keys and the event taps.
- Removing the grant while a tap is active (the input-freeze risk in the design).
- iTerm2, Ghostty, Microsoft Office, Notes, Slack, VS Code, `contenteditable` editors in a browser
  other than Obsidian's, bracketed paste with multi-line text, and Terminal's Secure Keyboard Entry.
- An Electron password field and native `NSSecureTextField`.
- Restoring non-text clipboard contents (images, files, promises).
