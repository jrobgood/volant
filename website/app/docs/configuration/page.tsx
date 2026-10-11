// oxlint-disable next/no-html-link-for-pages -- vinext 1.0.0-beta.5's next/link throws in the
// production build, leaving internal navigation dead. Plain anchors until fixed upstream.
import type { Metadata } from 'next';

import { adjacentDocs } from '../docs-nav';
import { DocFooterNav } from '@/components/doc-footer-nav';

export const metadata: Metadata = {
  title: 'Configuration — Volant docs',
  description:
    'The config.json reference for Volant: hotkeys, aliases, quicklinks, snippets, per-app hotkeys, and appearance.',
  alternates: { canonical: 'https://usevolant.com/docs/configuration' },
};

const example = `{
  "summonHotKey": "cmd+space",
  "notesHotKey": "option+n",
  "showOnLaunch": true,
  "showInDock": true,
  "clipboardRetention": 500,
  "appHotKeys": [
    { "bundleIdentifier": "com.mitchellh.ghostty", "hotKey": "meh+t" },
    { "bundleIdentifier": "md.obsidian", "hotKey": "meh+o" }
  ],
  "aliases": { "gh": "GitHub Desktop", "sys": "System Settings" },
  "snippets": [
    { "name": "Signature", "keyword": "sig", "body": "Andrew Lombardi" },
    { "name": "Today", "keyword": "td", "body": "{isodate}" }
  ],
  "quicklinks": [
    { "name": "Google", "url": "https://www.google.com/search?q={query}" },
    { "name": "Vault", "url": "obsidian://open?vault=Brain" }
  ],
  "appearance": { "scale": 1.0, "opacity": 1.0 }
}`;

export default function Configuration() {
  return (
    <>
      <p className="docs-breadcrumb">
        <a href="/docs">Docs</a> / Configuration
      </p>
      <h1>Configuration</h1>
      <p className="docs-lede">
        Volant keeps its settings in a single portable <code>config.json</code>.
        Choose <strong>Reveal Config Folder</strong> from the menu bar to find
        it, edit it, then choose <strong>Reload Config</strong>.
      </p>

      <div className="docs-note">
        <p>
          Edits are applied atomically and unknown keys are preserved, so a
          malformed file is rejected rather than silently overwriting what you
          had. A copy of this example ships inside the app.
        </p>
      </div>

      <h2>Keys</h2>
      <div className="docs-table-scroll">
        <table className="docs-table">
          <thead>
            <tr>
              <th>Key</th>
              <th>What it does</th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <td><code>summonHotKey</code></td>
              <td>Brings up the launcher. The example uses <code>cmd+space</code>; if the key is absent entirely, Volant falls back to <code>option+space</code>.</td>
            </tr>
            <tr>
              <td><code>notesHotKey</code></td>
              <td>Opens the floating notes window. Example: <code>option+n</code>.</td>
            </tr>
            <tr>
              <td><code>showOnLaunch</code></td>
              <td>Opens the launcher ready to type when the app starts.</td>
            </tr>
            <tr>
              <td><code>showInDock</code></td>
              <td>Whether Volant appears in the Dock or stays menu-bar only. Settings can change this live.</td>
            </tr>
            <tr>
              <td><code>clipboardRetention</code></td>
              <td>How many clipboard items to keep. Defaults to 500.</td>
            </tr>
            <tr>
              <td><code>appHotKeys</code></td>
              <td>Per-app hotkeys, each a <code>bundleIdentifier</code> plus a <code>hotKey</code>. Press once to activate or launch, again to hide.</td>
            </tr>
            <tr>
              <td><code>aliases</code></td>
              <td>Maps a word to an app name. The alias ranks first for that query.</td>
            </tr>
            <tr>
              <td><code>snippets</code></td>
              <td>Reusable text, each with a <code>name</code>, <code>keyword</code>, and <code>body</code>. You can also add one from the launcher with <code>new snippet</code>. See <a href="/docs/clipboard-and-snippets">Clipboard and snippets</a>.</td>
            </tr>
            <tr>
              <td><code>quicklinks</code></td>
              <td>Named URLs with an optional <code>{'{query}'}</code> slot. Supports http, https, mailto, and validated <code>shortcuts://run-shortcut</code> URLs. You can also add one from the launcher with <code>new quicklink</code>.</td>
            </tr>
            <tr>
              <td><code>appearance</code></td>
              <td><code>scale</code> from 0.8 to 1.4 and <code>opacity</code> from 0.5 to 1.0.</td>
            </tr>
          </tbody>
        </table>
      </div>

      <h2>Writing a hotkey</h2>
      <p>
        Hotkeys are modifier names joined with <code>+</code>, such as{' '}
        <code>cmd+ctrl+t</code>. Two shorthands exist for Karabiner users:{' '}
        <code>meh</code> is control+option+shift, and <code>hyper</code> is all
        four modifiers.
      </p>
      <p>
        Global hotkeys are registered through Carbon, which needs no
        permission — shortcuts need neither Accessibility nor Input
        Monitoring. From the next release, Volant asks for Accessibility only
        if you choose to have dictation typed at the cursor.
      </p>

      <h2>Example</h2>
      <pre>
        <code>{example}</code>
      </pre>

      <h2>Backing it up</h2>
      <p>
        <strong>Export Backup</strong> and <strong>Import Backup</strong> in the
        menu bar copy your configuration and notes to and from a folder you
        choose. Import shows every hotkey and quicklink it would install before
        applying anything. Clipboard history is deliberately excluded, because
        it is encrypted under this Mac&rsquo;s Keychain key and would not
        decrypt elsewhere.
      </p>

      <DocFooterNav {...adjacentDocs('configuration')} />
    </>
  );
}
