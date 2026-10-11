// oxlint-disable next/no-html-link-for-pages -- vinext 1.0.0-beta.5's next/link throws in the
// production build, leaving internal navigation dead. Plain anchors until fixed upstream.
import type { Metadata } from 'next';

import { adjacentDocs } from '../docs-nav';
import { DocFooterNav } from '@/components/doc-footer-nav';

export const metadata: Metadata = {
  title: 'Privacy and security — Volant docs',
  description:
    'App Sandbox, no network entitlement, no telemetry, encrypted clipboard history, and only the permissions Volant actually needs.',
  alternates: {
    canonical: 'https://usevolant.com/docs/privacy-and-security',
  },
};

export default function PrivacyAndSecurity() {
  return (
    <>
      <p className="docs-breadcrumb">
        <a href="/docs">Docs</a> / Privacy and security
      </p>
      <h1>Privacy and security</h1>
      <p className="docs-lede">
        There is no Volant account and no telemetry. Your notes, clipboard
        history, and learned ranking stay on your Mac. You choose what to share
        with AI. Selected settings can optionally sync through iCloud in the
        next release.
      </p>

      <h2>The main app has no network access</h2>
      <p>
        The main binary ships with <strong>no network entitlement</strong>, so
        it does not make direct network requests. Networked features use
        separate helpers or system services:
      </p>
      <ul>
        <li>
          <strong>Updates</strong> run through Sparkle&rsquo;s own separate
          helper process.
        </li>
        <li>
          <strong>Agent connections</strong> run through a separate local
          helper. See <a href="/docs/agents">Agents</a>.
        </li>
        <li>
          <strong>API and local-model chat</strong> use a separate sandboxed AI
          helper. Your selected server receives submitted prompts, chosen
          attachments, and completed turns. Keys stay in Keychain. Apple
          Intelligence uses the on-device model without this helper. See{' '}
          <a href="/docs/agents">AI connections</a>.
        </li>
        <li>
          <strong>iCloud settings sync</strong> uses Apple’s
          key-value service only when enabled. It shares selected global
          shortcuts, snippets, quicklinks, aliases, appearance, and
          clipboard-retention settings. Notes, clipboard history, API keys, AI
          configuration, app-specific shortcuts, and extension approvals are
          excluded. It is off until you turn it on in Settings → Data &amp;
          Configuration.
        </li>
        <li>
          <strong>Exchange rates</strong> come through a small
          rates helper that can reach only three fixed addresses. It downloads
          the European Central Bank&rsquo;s public daily rates the first time
          you type a currency conversion, and never before. Currencies the
          European Central Bank doesn&rsquo;t publish, such as the UAE dirham or
          the Taiwan dollar, use ExchangeRate-API&rsquo;s public daily rates,
          downloaded only the first time you convert one of them. Crypto prices
          come from CoinGecko&rsquo;s public price list the first time you
          convert a coin. An optional CoinGecko key stays in your Keychain and
          is sent only to CoinGecko. Nothing you type is included in any of
          these requests. See <a href="/docs/calculator">The calculator</a>.
        </li>
      </ul>
      <p>
        Opening a link hands it to another app. Running an Apple Shortcut hands
        execution to Shortcuts, whose workflows use their own permissions.
      </p>

      <h2>Permissions Volant asks for</h2>
      <div className="docs-table-scroll">
        <table className="docs-table">
          <thead>
            <tr>
              <th>Permission</th>
              <th>Why, and when</th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <td>Contacts</td>
              <td>
                Only to search contacts with <code>@</code>. Asked on first use.
              </td>
            </tr>
            <tr>
              <td>Calendar</td>
              <td>Only to show today and tomorrow. Asked on first use.</td>
            </tr>
            <tr>
              <td>Bluetooth</td>
              <td>Only to list connected paired devices.</td>
            </tr>
            <tr>
              <td>Microphone</td>
              <td>
                For on-device dictation with <code>talk</code>, on macOS 26 or
                later. Audio stays on the Mac; the transcript is copied for you
                to paste. From the next release, the Dictate Text shortcut
                shows a small indicator instead of the launcher, so the app you
                are typing in keeps focus.
              </td>
            </tr>
            <tr>
              <td>Location</td>
              <td>
                macOS requires it to read Wi-Fi network <em>names</em>. Volant
                never requests coordinates and never starts location updates.
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <p>
        Deny any of them and that feature simply returns nothing, with guidance
        and a System Settings action.
      </p>
      <div className="docs-note">
        <p>
          Be aware that Apple&rsquo;s Calendar grant is a full-access grant at
          the OS level. Volant only reads — but that restraint is the
          app&rsquo;s, not the operating system&rsquo;s.
        </p>
      </div>

      <h2>Permissions Volant does not ask for</h2>
      <p>
        <strong>No Accessibility grant. No Input Monitoring grant.</strong>{' '}
        Global hotkeys use Carbon&rsquo;s hotkey registration, which needs no
        permission at all.
      </p>
      <p>
        This is also why version 0.1 copies results to the clipboard instead of
        pasting them: no keystroke is ever synthesized. It is the reason
        paste-in-place, window management, and system-wide text expansion are
        absent — each would require that grant, and they were ruled out rather
        than quietly added.
      </p>

      <h2>Your data at rest</h2>
      <ul>
        <li>
          <strong>Clipboard history</strong> is AES-GCM encrypted with a 256-bit
          Keychain key scoped to this device while unlocked, stored in SQLite
          with <code>secure_delete</code>, and excluded from Time Machine.
          Password-manager copies are skipped unconditionally.
        </li>
        <li>
          <strong>Notes</strong> are ordinary <code>.md</code> files you can
          open in any editor.
        </li>
        <li>
          <strong>Configuration</strong> is a portable text file you can read,
          diff, and back up.
        </li>
        <li>
          <strong>Learned ranking</strong> lives in a local SQLite file. Nothing
          about it leaves the machine.
        </li>
      </ul>

      <h2>Code you can check</h2>
      <p>
        Volant is MIT licensed and its source is public. Its native features use
        Apple frameworks. Updates use Sparkle, and optional coding-agent
        connections may require separately installed CLIs and ACP adapters.
      </p>
      <p>
        Release builds are Developer ID signed, hardened, notarized, and
        stapled. The release script refuses to package an archive that carries
        debugger access, carries a network entitlement, or lacks a Developer ID
        signature — so a build that violated the posture above could not ship
        silently.
      </p>

      <DocFooterNav {...adjacentDocs('privacy-and-security')} />
    </>
  );
}
