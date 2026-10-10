# Clipboard recovery

Issue #31: clipboard history previously appeared empty when Keychain or SQLite was unavailable, and the key was fixed for the lifetime of the store. Keychain lookup statuses were collapsed into nil, including temporary access failures.

The store now retains typed Keychain failures and publishes a bounded state: ready, retrying or unavailable. The `clip` view distinguishes an empty result from unavailable storage, shows a native Retry Clipboard History button (Command-R), and displays progress. Existing readable rows can remain alongside an unreadable-entry warning. Store failures do not change other launcher queries.

Retry runs on the existing storage queue after earlier writes, reopens SQLite and reloads the original key. It never deletes the database or replaces a key. A new key is created only for errSecItemNotFound with an empty history database; existing encrypted rows without their key remain intact and unavailable. A concurrent key-creation race rereads the winner. Malformed keys and other OSStatus failures are explicit errors. No plaintext fallback, automatic reset or replay of missed clipboard captures. Capture remains paused while unavailable/retrying; copies made then must be copied again after recovery. The current pasteboard is not read by Retry.

SQLite open/schema/read/write failures are surfaced; old pre-kind schemas retain their migration. Decryption failure preserves the affected rows and pauses subsequent writes/trimming rather than silently reporting a fully readable history. Recovery does not promise to repair corruption or restore a lost key. Messages never contain clipboard content, raw Keychain errors or database paths. Retention and encryption behavior remain unchanged for healthy storage.

## Validation

ClipboardRecoveryTests uses isolated SQLite files, generated keys and injected Keychain operations. Covers access denial/cancellation/auth failure without key creation, first creation, duplicate-key races, malformed keys, existing-history protection, unavailable-key retry, ciphertext preservation, database open/write failure, unreadable rows, deduplicated Retry, query changes during recovery and whitespace-preserving clipboard search. No owner Keychain or clipboard access.

Native Actions fixtures use fictional encrypted rows and a fake key loader, covering unavailable/progress/recovered/empty-search states and actual Command-R button dispatch. Run in Tart in light/dark at compact/default/large launcher sizes; inspect the rendered fixtures separately. Shared classifier now includes clipboard dependencies so future error-state changes select UI checks.

Signed installed-app Keychain denial/regrant remains separate evidence; do not revoke owner access to simulate failure. This change does not implement image memory budgets (#17) or Keychain recovery for other services.

## Prevention

Treat missing secrets differently from inaccessible secrets. Never regenerate encryption keys on arbitrary lookup failure. Keep recovery injectable, preserve ciphertext, and test that a successful Retry does not replace a later launcher query. These failure/persistence checks and native UI fixtures run in CI; real OS Keychain prompt behavior is not established by fixtures.

## Mixed image and text copies

Issue #30: a copy carrying both text and an image was stored as text only, and text over the 256 KB cap aborted the poll before the image was read. `PasteboardCapture` (VolantCore) now judges each representation independently: text within the cap and a PNG (or TIFF converted to PNG) within 8 MB are both recorded, the image last so it is the newest row. Oversized text no longer blocks the image. `PasteboardFilter` exclusions, size caps and encryption are unchanged. JPEG, PDF and file-URL representations are still not captured. `PasteboardCaptureTests` uses fictional bytes only; whether a given design app writes a non-empty string beside its image needs a real copy from that app.
