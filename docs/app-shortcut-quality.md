# App shortcut activation

## Symptom and diagnosis

On 2026-09-17, the installed app's Claude shortcut was confirmed in Settings as
`cmd+ctrl+option+shift+c` (✦ C). The owner's Caps Lock mapping supplies Control,
Option and Shift; adding Command matches this shortcut. Command-Space summoned
Volant. The owner reported that Claude did not come forward during the scripted
Hyper-C checks. No shortcut registration error was displayed.

The old running-app path called `NSRunningApplication.activate()` and discarded
its return value. Unlike normal launcher activation, it never sent a reopen
request. This is a concrete gap, but the original failure has not yet been
attributed conclusively to event delivery versus activation. Desktop automation
stalled and its app-specific snapshots did not establish foreground ownership.

## Change and prevention

Inactive targets now use `NSWorkspace.openApplication`, including apps already
running. The running process's bundle URL takes precedence over a Launch Services
lookup. The configuration explicitly activates and unhides the target. A
frontmost target still hides on the next press.

Missing apps, rejected hides and failed asynchronous opens report an error in the
existing Settings error area and sound a beep. Event-handler installation and
registration failures are logged. The `AppShortcuts` log category records when a
configured shortcut reaches its action, with running/active booleans only; it
does not monitor or log arbitrary keyboard input or app content.

## Evidence and remaining checks

- 101 native tests passed, including four new tests covering open/hide dispatch,
  missing applications, rejected hides, and asynchronous open success/failure.
- These injected logic tests do not establish global Carbon event delivery or
  foreground activation on the owner's macOS version.
- Headless Tart UI checks passed in `volant-ui-vm-xp5_lyt1`.
- Signed Release build and deep/strict bundle verification passed. Installed
  executable SHA-256:
  `e621aae13471c06cf45794852e251e16cac0119514abd41c6309a1d6158ad749`.
- The owner confirmed physical Caps Lock + Command + C opens Claude with this
  installed build. At 20:46:24 local time the matching action log recorded
  `running=true, active=false`; no handoff failure was logged. The successful
  case exercises the changed already-running/inactive path.
- Automation-generated Hyper-C produced no delivery log and is not counted as
  global-hotkey evidence. Do not infer physical-key failure from those injected
  events. A restart accompanied the install, so this test alone does not prove
  which factor caused the original failure.
- The owner also confirmed installed Hyper-S works and a second Hyper-C hides
  frontmost Claude. No saved bindings were changed.
- Remaining: other configured bindings and reopening an app after its last
  window closes. Automated tests do not yet cover physical global key delivery.

If installed verification still fails, first check for an `App shortcut delivered`
event in subsystem `com.mysticcoders.volant`, category `AppShortcuts`. Its absence
points to registration/delivery; its presence narrows the next check to the app
handoff. Do not label a saved shortcut or successful open callback proof that an
app reached the foreground.

## CI fixture timing

The final CI run initially failed the dark compact Herdr preview assertion after
the light, dark and light compact variants passed. That fixture allowed a fixed
200 ms for SwiftUI's presentation task to start. It now installs the fictional
reader before publishing the sessions, then waits at most three seconds for both
the loading state and the reader callback. Missing preview behavior still fails;
the fixture no longer equates a busy runner with a missing preview. This is an
automated fixture change, not a change to production Herdr or shortcut behavior.

## Choosing between installed copies

Each app shortcut now records the selected application's path alongside its
bundle identifier. With two copies of one application installed (a release and a
beta, or `/Applications` and `~/Applications`), the shortcut opens, focuses or
hides only the copy chosen in Settings; a different copy that is running or
frontmost is ignored. Two copies can hold separate shortcuts.

Entries saved before this change have no path and keep resolving by bundle
identifier until edited. They are not rewritten at launch, because filling in
Launch Services' current choice would freeze the same ambiguity. Editing the
shortcut or alias in Settings records the selected copy and keeps the entry's
unknown fields. If the saved copy is gone or its path now holds a different
application, the shortcut falls back to the bundle identifier and logs that the
copy was unavailable. Raycast import records the exported application path.

Application search still indexes at most one subfolder below an application
folder, so vendor uninstallers and helpers nested deeper stay out of fuzzy
results. A saved path alias to a deeper application bundle that still exists
resolves directly instead of disappearing.

Injected logic tests cover copy selection, legacy fallback, migration and stale
edits. Global hotkey delivery to the intended copy in the installed app has not
been verified.
