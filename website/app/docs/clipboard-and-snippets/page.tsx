// oxlint-disable next/no-html-link-for-pages -- vinext 1.0.0-beta.5's next/link throws in the
// production build, leaving internal navigation dead. Plain anchors until fixed upstream.
import type { Metadata } from 'next';

import { adjacentDocs } from '../docs-nav';
import { DocFooterNav } from '@/components/doc-footer-nav';

export const metadata: Metadata = {
  title: 'Clipboard and snippets — Volant docs',
  description:
    'Locally encrypted clipboard history for text and images, plus reusable snippets with date and clipboard placeholders.',
  alternates: {
    canonical: 'https://usevolant.com/docs/clipboard-and-snippets',
  },
};

export default function ClipboardAndSnippets() {
  return (
    <>
      <p className="docs-breadcrumb">
        <a href="/docs">Docs</a> / Clipboard and snippets
      </p>
      <h1>Clipboard and snippets</h1>
      <p className="docs-lede">
        Keep the good copies, and reuse the text you keep retyping. Both stay on
        your Mac.
      </p>

      <h2>Clipboard history</h2>
      <p>
        Type <code>clip</code> to browse what you have copied. Return puts the
        selected item back on the pasteboard. Volant never pastes for you — see{' '}
        <a href="/docs/privacy-and-security">Privacy and security</a> for why
        that matters.
      </p>
      <p>
        History holds 500 items by default; change it with{' '}
        <code>clipboardRetention</code> in your{' '}
        <a href="/docs/configuration">configuration</a>.
      </p>

      <h3>Images</h3>
      <p>
        PNG and TIFF copies are stored encrypted exactly like text, shown as
        thumbnails under <code>clip</code>, and put back on the pasteboard with
        Return. TIFF copies are stored as PNG. Images are capped at 8 MB each.
        A copy that carries both an image and text, as many design apps make,
        records both.
      </p>

      <h3>How it is protected</h3>
      <ul>
        <li>
          Encrypted at rest with AES-GCM under a 256-bit key held in the
          Keychain, scoped <code>WhenUnlockedThisDeviceOnly</code>.
        </li>
        <li>
          Stored in SQLite with <code>secure_delete</code> on, and excluded from
          Time Machine.
        </li>
        <li>
          Password-manager copies are skipped unconditionally, honoring the{' '}
          <code>ConcealedType</code>, <code>TransientType</code>, and{' '}
          <code>is-sensitive</code> pasteboard markers.
        </li>
      </ul>
      <div className="docs-note">
        <p>
          Because the key belongs to this Mac&rsquo;s Keychain, clipboard
          history is deliberately excluded from backup and import — it would not
          decrypt anywhere else.
        </p>
      </div>

      <h2>Snippets</h2>
      <p>
        Define snippets in your configuration, each with a name, a keyword, and
        a body. Type <code>snip</code> to list them, or type a keyword directly.
        Return copies the body with its placeholders expanded.
      </p>

      <h3>Placeholders</h3>
      <div className="docs-table-scroll">
        <table className="docs-table">
          <thead>
            <tr>
              <th>Placeholder</th>
              <th>Expands to</th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <td><code>{'{date}'}</code></td>
              <td>The current date.</td>
            </tr>
            <tr>
              <td><code>{'{isodate}'}</code></td>
              <td>The current date in ISO form.</td>
            </tr>
            <tr>
              <td><code>{'{time}'}</code></td>
              <td>The current time.</td>
            </tr>
            <tr>
              <td><code>{'{datetime}'}</code></td>
              <td>Both together.</td>
            </tr>
            <tr>
              <td><code>{'{clipboard}'}</code></td>
              <td>The current clipboard contents.</td>
            </tr>
            <tr>
              <td><code>{'{uuid}'}</code></td>
              <td>A freshly generated UUID.</td>
            </tr>
          </tbody>
        </table>
      </div>
      <p>
        Snippets are copied, never typed into the app in front of you. Expanding
        text as you type in any application would require an Accessibility grant
        and a keyboard event tap, which Volant does not ask for.
      </p>

      <DocFooterNav {...adjacentDocs('clipboard-and-snippets')} />
    </>
  );
}
