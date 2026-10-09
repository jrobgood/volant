# Native agent integrations

Scope requested: Herdr panes plus OpenCode, Cursor, Claude Code and Codex sessions inside Volant. Delivered development slices: native Herdr discovery/focus and inline ACP v1 conversations, verified end to end with OpenCode, Claude Code and Codex. Claude/Codex use maintained ACP adapters rather than separate native conversation transports. Historical slice notes below record the earlier state.

- Herdr: local socket API for discovery, state, focus and explicit prompts. Installed at ~/.local/bin/herdr; CLI exposes api schema, agent list/get/focus/prompt and pane operations.
- OpenCode: ACP over stdio. Installed at /opt/homebrew/bin/opencode; acp subcommand confirmed locally. Negotiate installed capabilities instead of assuming current website docs match this version.
- Cursor: ACP via agent acp. The agent executable was not found on PATH; detect its supported installation path and present setup instructions if absent.
- Claude Code: researched as an Agent SDK integration; shipped through the `@agentclientprotocol/claude-agent-acp` ACP adapter (see the note above). Herdr for existing terminal panes.
- Codex: researched as the native app-server protocol; shipped through the `codex-acp` ACP adapter. Do not equate saved thread discovery with attaching to arbitrary running desktop conversations.

Sources: https://herdr.dev/docs/socket-api/ ; https://opencode.ai/v2/docs/cli/acp/ ; https://cursor.com/docs/cli/acp ; https://code.claude.com/docs/en/agent-sdk/overview ; https://learn.chatgpt.com/docs/app-server

Next implementation slice:
1. Prove sandbox-to-local-harness connectivity in an isolated spike. Volant and its extension XPC service are sandboxed; neither automatically grants a spawned agent project or network access. Evaluate an optional local companion with scoped IPC.
2. Normalize provider/session/project identity and capabilities; keep pane identity separate from conversation identity.
3. Add native Agents results: attention states, status, selected-session detail and focus. Expose unsupported/unknown states honestly.
4. Add explicit note/snippet context preview and prompt submission; never send clipboard history implicitly. Keep terminal approval dialogs in their owning pane until structured permission handling is supported.
5. Implement ACP streaming, cancellation, permissions, Cursor blocking extensions, then Claude SDK and Codex app-server adapters behind the same interface.

Validation: no agent tasks or user-pane mutations performed during initial discovery. Use fictional project fixtures for protocol and permission tests. Include disconnect, stale session, duplicate submission prevention and cancellation behavior.

## First slice delivered

Open Agents from the Volant menu or type `agents` / `herdr` in the launcher. Connect Herdr explicitly. Search project/provider/status, refresh, disconnect, and focus an agent pane. Closing the panel disconnects and stops polling. This version targets only the default local Herdr session.

The main app stays sandboxed. VolantAgentHost is a separately signed, intentionally unsandboxed embedded XPC service with a narrow list/focus interface. It authenticates the calling app against the Volant bundle identifier and team. It executes the installed Herdr CLI by absolute path without a shell or inherited pane context. It cannot receive arbitrary commands, prompts, filenames, or clipboard content through its interface. Herdr output is bounded and command execution has an eight-second termination timeout.

Focus re-reads live state and checks pane ID, terminal ID, provider and native session identity when available. If Herdr supplies no native session ID, identity falls back to provider plus terminal ID: a same-provider restart inside the same terminal cannot be distinguished reliably. Do not claim stronger identity guarantees. Focus changes selection in Herdr; automatic activation of the owning terminal application is not implemented.

Validation: signed Release app-to-XPC discovery succeeded (29 live sessions), and focus succeeded against this task's own Herdr pane. Isolated model checks passed for attention-first sorting, unknown status, identity and malformed payloads. Fictional native panel renders inspected in light and dark. Website desktop (1440) and mobile (390) renders inspected. Complete live keyboard navigation, alternate sessions/machines, enlarged accessibility text, and every error state remain unverified.

Next: ACP transport initialization and capability negotiation for OpenCode/Cursor; then session prompts, streaming, cancellation and explicit approvals. Follow with Claude SDK and Codex app-server adapters. Do not market these as shipped before end-to-end verification.

Rendering lesson: a transparent NSHostingView captured white behind dark controls. An explicit semantic windowBackgroundColor now covers the panel; both appearances were inspected after the fix. Use a compiled SwiftUI fixture renderer with a short run-loop layout pass, since the interpreter failed to link SwiftUI in this environment. No automated visual gate exists yet.


## Inline launcher status — September 13

Herdr panes now appear in the main launcher, replacing the separate Agents window. Type `agents` or `herdr`, then Connect; append a provider or project name to filter. Arrow keys select the normal result rows and Return requests validated Herdr pane focus. Focus success/failure is shown inline; Herdr focus does not bring the terminal application forward.

Use the pin menu, a pane's context menu, or Settings → Pinned harness to promote All Herdr agents, OpenCode, Cursor, Claude Code, or Codex below the search field. The summary remains during other searches and opens its filtered pane list. The preference is optional and persisted without replacing unrelated configuration. A pinned harness connects while the launcher is visible; hiding the launcher disconnects and stops polling.

Validation: universal Release build; isolated preference round trips, invalid-value rejection and unrelated-field preservation; actual status-strip rendering at 600/750-point widths in Aqua and Dark Aqua. These fixtures do not establish full-window keyboard/menu or live OS appearance verification. The standalone Agents window was removed to prevent fragmented navigation.

Next: verify full launcher and Settings interactions on the owner's desktop, then implement native ACP sessions/streaming/permission requests. Herdr pane metadata remains distinct from ACP conversation state; direct provider conversation adapters have not shipped.

Installed artifact verification: `/Applications/Volant.app` passed deep/strict signature verification; its signed XPC diagnostic listed 30 live panes and successfully focused only the current task pane. Native Settings light rendering was inspected. Dark Settings captures remained blank in the render harness, so dark Settings and full-window live interaction remain unverified; status-strip Aqua/Dark Aqua fixtures both rendered and were inspected. The standalone preference checks passed; the hosted XCTest suite was not run for this slice.


## ACP conversation slice — September 13

Implemented in the main launcher (`acp`): provider/project selection, a new Volant-owned session, streamed text, tool status, prompt submission, Cancel, End, and explicit permission choices with operation details. An activity row preserves access while searching elsewhere. Hidden windows retain their conversation; app/helper disconnect ends the owned process. No existing Herdr pane receives prompt input.

The signed helper launches fixed `opencode acp` / `agent acp` executables without a shell. It negotiates ACP v1, validates session IDs, rejects duplicate prompts and stale permission selections, answers pending permission requests as cancelled on cancellation, and returns method-not-found for unsupported client calls. Client filesystem and terminal capabilities are false. JSON framing, transcript/tool metadata, permission queues and prompt sizes have limits; startup and cancellation have deadlines. A separate writer queue keeps a stalled stdin from blocking cancellation. Native session identity is owned by the helper, not accepted from UI prompt arguments.

Credential/network/file scope: the helper remains intentionally unsandboxed; project selection is working context, not enforced filesystem confinement. The provider uses its existing credentials, configuration, permissions and network access. Provider configuration may authorize tools without issuing ACP permission requests. Volant only displays and answers requests the provider emits; it is not a replacement security boundary. It sends only explicit prompt text. No clipboard/notes handoff, authentication UI, model selection, session resume or provider-specific blocking extensions shipped in this slice.

Evidence: universal signed Release build passed. `./tools/check-acp.sh` passes fragmented/coalesced frames, v1 negotiation, session routing, text streaming, duplicate prompt rejection, explicit/rejected/invalid/stale permission choices, cancellation including late approvals, unsupported client methods, and malformed frames. Signed app→XPC→installed OpenCode initialization/session creation and a one-line no-tools prompt in `/tmp/volant-acp-fixture` passed. Conversation and permission fixtures rendered in Aqua/Dark Aqua and compact sizing; fixture rendering is not live keyboard or project-picker verification. Cursor CLI is absent, so Cursor has not been verified. No claim is made for direct Claude Code/Codex conversations.

Regression lesson: an older snapshot could arrive after prompt submission and briefly restore Ready. UI mutation revisions now discard pre-mutation snapshots; the helper independently rejects concurrent prompts. Protocol regression checks are automated locally by the script; no CI workflow yet.

Next concrete work: live keyboard/project-picker/approval UX verification; Cursor CLI installation and provider extensions; negotiated model/mode selection and session restore; then Claude Code SDK and Codex app-server adapters. Keep marketing tagged in development until release verification.

Installed delivery evidence: `/Applications/Volant.app` passed deep/strict code-signature verification and repeated the OpenCode ACP session + expected-response check successfully. Real tool execution/approvals, Cursor, full launcher keyboard handling and the project picker remain unverified; do not infer them from the protocol fixture or view renders.


## Claude Code and Codex through ACP — September 13

Added both providers to the same inline conversation UI. Locked adapter packages are `@agentclientprotocol/claude-agent-acp@0.76.0` and `@agentclientprotocol/codex-acp@1.11.0`, with reproducible dependency versions in `Integrations/acp/package-lock.json`. `Scripts/install-acp-adapters.sh` installs them into `~/.local/share/volant/acp`. A Node 22+ runtime is required. The helper executes Node by absolute path, passes only the known adapter entrypoint, and sets `CLAUDE_CODE_EXECUTABLE` / `CODEX_PATH` to an installed CLI. No shell or startup package download is used. Both signed app/helper conversation checks returned the expected no-tools response using existing logins. Tested CLI versions: Claude Code 2.1.270 and Codex 0.154.0. Cursor remains unverified.

Authentication lesson: Claude worked directly but failed with “Authentication required” through XPC. The helper was in a new audit/security session, so the provider could not see the login Keychain. `XPCService.JoinExistingSession = true` joins the caller’s security session; the signed Claude ACP prompt then passed. Do not copy OAuth tokens or weaken Keychain ACLs as a workaround. Initialization/session creation alone does not verify authentication; include a minimal prompt in delivery smoke checks.

Sources: [Claude ACP adapter](https://github.com/agentclientprotocol/claude-agent-acp), [Codex ACP adapter](https://github.com/agentclientprotocol/codex-acp), [Apple XPC security session configuration](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingXPCServices.html).

Next: verify real provider tool approvals and live keyboard/project selection; Cursor setup; negotiated model/mode selection and session restore. Provider-specific extensions and notes/context handoff remain outside this slice.

Installed verification: both `--acp-provider claude` and `--acp-provider codex` passed session creation and expected-response checks from `/Applications/Volant.app`; the installed app passed deep/strict signature verification. Claude/Codex provider labels were inspected in native light/dark view renders. Actual provider tool approvals and live keyboard/project-picker behavior remain unverified.


## Agent detection and per-pane change state — September 30, 2026

Prompted by JetBrains Air's agent discovery and per-session change tracking (see
`docs/competitors.md`).

**Detection.** Settings → AI (ACP) lists every provider as ready, needs adapter, needs Node, or not
installed, with Use for a ready one. `ACPAgentResolver` in Core is the single lookup behind both
detection and Connect, so Settings cannot report an agent ready that Connect then fails to find.
It searches `~/.local/bin`, Homebrew, `/usr/local/bin` and mise/nvm Node bins; node and OpenCode
keep their original search order. Detection only checks files through the helper's
`detectACPAgents`: it starts nothing and reads no credentials, so "ready" does not mean signed in.
Gemini CLI and Qwen Code are new providers, both started with `--acp` (Gemini's docs deprecate
`--experimental-acp`). Qwen Code 0.23.3 on the development Mac answered a real `initialize` with
protocol version 1 and `embeddedContext`, image and audio prompt capabilities. Gemini was not
installed there and is unverified beyond its documentation.

**Change state.** Local Herdr panes show `branch · N changed · N ahead · N behind` (or `clean`)
from their working folder, and a dot when the pane's Herdr state counter moved since the owner last
looked and the agent is now blocked, done or idle rather than working. Focusing a pane from Volant,
answering its question, or Herdr reporting it focused all count as looking. The status strip adds
"N new". Unread state is in memory only.

The helper runs exactly `RepositoryStatusCommand`:
`git -c core.fsmonitor=false --no-optional-locks status --porcelain=v2 --branch
--untracked-files=normal --ignore-submodules=all`. Environment is minimal with
`GIT_OPTIONAL_LOCKS=0` and no terminal prompts; timeout 3 s; at most 32 folders per request; counts
and branch only, no file names. `/usr/bin/git` is never used, because on a Mac without the Command
Line Tools it opens an installer dialog. The model re-reads a folder only when one of its panes
changed state or 30 seconds have passed, not on every five-second pane refresh. Remote panes are
not inspected yet; that needs the same command over the Herdr machine's SSH route.

Evidence: resolver, parser and command tests in Core, including the exact command against a
throwaway repository (and that it leaves no `index.lock`); model tests for unread, per-folder
sharing, re-read throttling, remote exclusion and late-reply rejection; `tools/check-acp.sh`.
Not verified: the Settings list and row decorations in the signed installed app with real panes.

## Do the ACP adapters load existing MCP configuration? — September 30, 2026

Yes, both do, so Volant does not keep its own MCP server list.

**Source.** `claude-agent-acp` 0.76.0 starts the Claude Agent SDK with
`settingSources: ["user", "project", "local"]`, so Claude Code's own MCP configuration applies.
Servers sent in ACP `session/new` are merged on top and win on a name clash. `codex-acp` 1.11.0
drives Codex's own app-server, so `~/.codex/config.toml` layers apply. ACP-provided servers are
added as a config overlay and, by default, skipped when a configured server has the same name.
The Codex adapter also marks the session's working folders `trust_level = "trusted"` in that
overlay, which is one more reason the working folder is not a sandbox.

**Live check, zero tokens.** Each adapter was started exactly as Volant starts it, sent
`initialize` and `session/new` with `mcpServers: []` in a throwaway folder, and never prompted.
Every configured stdio server then appeared as a child process: 8 of 8 for Claude Code. The two
remote HTTP/SSE servers could not be checked this way. For Codex, 2 of 3 appeared; the third is
`enabled = false` in the owner's config and correctly did not start. Only server names were
recorded, never command lines, which can carry credentials. All adapter processes were stopped
afterwards.

**Consequence.** A Volant-wide MCP list would duplicate servers for Claude Code and Codex. Its only
value would be agents without their own configuration. Gemini CLI and Qwen Code both keep their
own settings files, which have not been checked here. Revisit only if an agent is found that
ignores its own configuration under ACP, or if Volant itself should be offered to agents as an MCP
server, which is a separate design with sandbox implications.

## Resuming an ACP conversation

An ACP chat could not be continued once End, quitting Volant or a helper crash ended it:
Volant only ever sent `session/new` and kept no session ID, and its transcript lives only in
memory and stays on screen until the next Start. The pinned adapters keep their own conversation history and advertise
`loadSession` (`claude-agent-acp` 0.76.0 and `codex-acp` 1.11.0 both implement
`session/load`, which replays the history as `session/update` notifications), so Volant
restores a conversation by sending `session/load` with its recorded native session ID.

**Record.** Once a conversation is ready and holds at least one owner turn, the app stores
`ACPResumeRecord` (provider, the project exactly as chosen, the native session ID, a
timestamp) in its own defaults under `acp.lastConversation`. Only the latest conversation is
kept; a new conversation replaces it only after its first prompt, so a session opened and left
unused never discards the record. The `--acp-check` smoke run keeps its record in a
separate defaults suite, so it never replaces the owner's. The record is not in
`config.json`, so it is neither backed up nor part of iCloud settings sync, and it holds no
transcript text.

**Resume.** The chat header shows Resume beside New when the record's provider and project
equal the current choice, so a conversation is never reopened in another folder. Opening AI
Chat, from the launcher or from Settings, connects automatically only when no such record
exists; otherwise it waits for Resume or New. Resume
starts the provider exactly as Connect does, then, after `initialize`:

- sends `session/load` with the recorded ID, the resolved working folder and no MCP
  servers, only if the agent advertised `loadSession`;
- otherwise ends with "This agent can't resume conversations", sends nothing else and clears
  the record.
  It never falls back to `session/new`, because the owner asked for a specific
  conversation;
- shows the replayed history, including the owner's own turns (`user_message_chunk`),
  which are accepted only while a resume is loading. During a live turn the transcript
  already holds the prompt Volant sent, so an echo is ignored;
- cancels any permission request that arrives during the replay, as for every phase other
  than an active turn;
- treats a load error as the end of the connection, with the agent's message
  ("Couldn't resume this conversation: ..."), and clears the record. A launch failure or
  startup timeout keeps it, since the cause may be an expired provider login with the
  conversation still intact. Error codes cannot identify a missing conversation:
  `claude-agent-acp` 0.76.0 loads an unreadable transcript as empty history instead of
  failing.

Because the stored ID came from the agent, it is checked again before it is sent back: 1 to
256 printable ASCII characters, with no spaces, slashes or control characters. The helper
repeats the check before launching anything. A replay keeps only its newest 400,000 bytes of
displayed text and 800 entries, dropping the oldest and reporting "Earlier history isn't shown",
so a long conversation resumes with room left under the live limits (1,000,000 bytes and 2,000
entries). Replayed tool details are not stored, since no approval is offered for them.

Not included: `session/list` (choosing among earlier conversations), `session/resume`
without replay, and resuming Herdr panes, which belong to Herdr.

Evidence: `ACPResumeRecordTests` in Core; `tools/check-acp.sh` for load-by-ID, replay of both
sides, approvals refused during replay, the user-echo guard, replay trimming, the
missing-capability and load-error failures with their record clearing, and refusal of an
invalid ID before launch. `ACPResumeModelTests` covers the offer rules, opening the chat without
replacing the record, saving only after an owner turn, and clearing a rejected record, against
an isolated defaults suite; other ACP model tests use the same isolated suite. Not verified: the signed installed app
resuming a real Claude Code, Codex or OpenCode conversation, and the Resume and New buttons in
native light and dark renders.

## Spawned process environments

Every process Volant spawns receives an explicit, complete environment built by `ChildProcessEnvironment` in VolantCore; none inherits the caller's. The base is `HOME`, `USER`, a fixed `PATH` and `LANG=en_US.UTF-8`. Each spawn adds only what it names:

- ACP providers: the provider executable's folder first, then `~/.local/bin`, Homebrew and the system folders including `sbin`, plus the resolver's launch variables such as `CLAUDE_CODE_EXECUTABLE`.
- Herdr CLI: `~/.local/bin`, Homebrew and system folders without `sbin`, plus `SSH_AUTH_SOCK` when the helper has one, for saved remote machines.
- Apple tools (`/usr/bin/shortcuts` in the agent helper, `/usr/bin/pmset` in the app): system folders only.
- git status for change counts keeps its own `LC_ALL=C` environment (`RepositoryStatusCommand.environment`).

The fixed locale is intentional. Volant reads ACP JSON-RPC, Herdr JSON and the Shortcuts identifier listing as machine-readable output, so the child needs a UTF-8 codeset that is guaranteed to exist: without `LANG`, many tools fall back to the ASCII C locale and mangle non-ASCII project names, prompts and shortcut names. `Locale.current` is not used because its identifiers (for example `en_DE` or `zh-Hans_CN`) do not map one to one onto installed POSIX locales; an unknown value makes tools print `setlocale` warnings and still fall back to C, and the same input would behave differently on different Macs. An agent's reply language is set by the prompt and the provider, not chiefly by `LANG`; the locale mainly affects formatting inside tool output. git uses `C` instead because its porcelain parsing must be byte-stable and its messages are never shown.

The accepted cost: text an agent's tools format through the locale, such as dates or decimal separators in a command's output, appears in US English style regardless of the owner's region. Deriving a validated per-user locale for provider processes remains possible later; it would apply only to ACP providers and must fall back to `en_US.UTF-8` when the derived name is not installed. Tests cover the builders with fictional values only; they do not run Shortcuts, pmset or providers.

## Several conversations — October 9, 2026

Volant ran one ACP conversation at a time. Starting another meant ending the running one, so a
second question cost the first agent its place. The helper already builds one `AgentHost`, and so
one `ACPConnection`, for each XPC connection, and each `ACPModel` opens its own connection, so
several models are several independent conversations with no protocol change.

**List.** `ACPConversations` holds the launcher's conversations in the order they started; one is
current and shown in AI Chat. While a conversation runs, the header shows New beside End. New
starts a conversation with the provider and folder saved in Settings and shows it, and the one
that was shown keeps running in its own helper connection. With incomplete settings, or a BYOK
connection without a stored key, it opens AI Settings instead, as opening AI Chat does. A current
conversation that is not running and holds no transcript, such as one that failed to launch, is
started in place. With more than one conversation to show, a row of buttons under the header lists
them with the provider, the folder's last path component, the first line of the owner's first
message cut to 24 characters, a raised hand while one waits for a permission and a small spinner
while it works; selecting one shows it. New always uses the saved provider and folder, so that first
line is what tells two such conversations apart once each has a turn. A conversation that ends while
another is shown leaves the row at once; its in-memory transcript is discarded the next time a
conversation is selected or New beside End opens another. The shown conversation keeps its
transcript after End until the next Start, as before.

**Limit.** Up to 6 conversations run at once (`ACPConversationLimit.live`). The app disables New
at the limit and refuses a seventh conversation with "Volant runs up to 6 conversations at once.
End one to start another." The helper counts the same limit in one `ACPConversationSlots` shared
by every connection in its process; the service runs one process for the app.
`ACPConnection.start` takes a slot before it resolves the provider or launches anything, and
returns it if the start ends before an agent runs; `stop` returns it on process exit, every
failure, `acpStop` and XPC invalidation. Conversations through an HTTP API or Apple's model count
toward the app's limit and take no helper slot. The two counts can briefly disagree: the app counts
a conversation as ended when End runs, and the helper frees its slot when that connection's
invalidation reaches it, which nothing orders against a start on another connection. A start that
reaches the helper first, with six conversations counted there, is refused with the limit message.
The length of that window has not been measured.

**Polling.** A poll of an unchanged conversation gets no data, since the helper skips unchanged
snapshots, but while an agent streams each poll decodes the whole transcript on the main thread. The
shown conversation still polls every 0.25 s, and the others poll once a second
(`ACPModel.pollInterval`). Six streaming conversations at 0.25 s would decode up to 24 transcripts
a second; with one shown and five behind it, the most is 9.

**Launcher and Settings.** With one live conversation, the AI Chat row in search looks as it did.
With several it stays one row: AI Chat, then a badge per live conversation with its provider, the
same first line of its first message and a raised hand while it waits for a permission. A badge
opens its conversation. Open conversation opens the first one waiting for a permission, else the
shown one while it runs, else the first running one. It never opens an ended conversation, because
opening AI Chat on one can start a new conversation in its place. Settings → AI reads
"N conversations running" when more than one runs; its button opens the shown conversation, or
connects it once it has ended, as before.

**Resume.** Every conversation shares the one record under `acp.lastConversation`. A conversation
writes it once, when it is ready and holds its first owner turn, so the record names the
conversation that wrote it last. A refused `session/load` clears the record only while it still
names the session that conversation asked to load, so a record another conversation wrote since
survives. Each conversation reads the record when it is made, so a refusal also tells every other
conversation to stop offering that session, including one made while the load ran. Resume is not
offered for a session another live conversation holds or is loading, so Volant never runs one
session in two agent processes, and the shown conversation's header updates when a conversation
behind it starts or ends.

Evidence: `ACPConversationSlotsTests` in Core (5 tests, including 200 concurrent acquire and
release pairs that never exceed the limit). A new `tools/acp/check.swift` case refuses a start at
the limit before the provider or folder is resolved, and returns the slot after a failed start and
on stop; altered copies of the helper without the release in `stop`, or taking the slot after the
folder is resolved, fail it. `ACPConversationsTests` (12 tests) covers New, reuse of an unused
conversation, the limit, dropping ended conversations, the poll intervals, which changes reach
observers, the launcher's choice of conversation, the shared resume record, the first-message
label and the BYOK key check. On GitHub's macos-15 runner, `Scripts/test.sh --ci --ui never`
passed, those 12 tests and the ACP check included; the UI job, which renders
`ai-acp-several`, `ai-acp-several-strip` and `ai-acp-several-settings` through
`tools/check-launcher-actions.sh`, passed; and `swift test --package-path Core` passed,
the 5 above included. Volant's PR checks build Core but do not run its package tests. Not verified:
several live conversations with real providers in the signed installed app, and the conversation
buttons, the launcher row and the AI Settings count inspected in light and dark renders.
