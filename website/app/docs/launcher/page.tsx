// oxlint-disable next/no-html-link-for-pages -- vinext 1.0.0-beta.5's next/link throws in the
// production build, leaving internal navigation dead. Plain anchors until fixed upstream.
import type { Metadata } from 'next';

import { adjacentDocs } from '../docs-nav';
import { DocFooterNav } from '@/components/doc-footer-nav';

export const metadata: Metadata = {
  title: 'The launcher — Volant docs',
  description:
    'Search apps, files, and contacts, calculate, convert units, check today’s agenda, and use prefixes to force a single source.',
  alternates: { canonical: 'https://usevolant.com/docs/launcher' },
};

export default function Launcher() {
  return (
    <>
      <p className="docs-breadcrumb">
        <a href="/docs">Docs</a> / The launcher
      </p>
      <h1>The launcher</h1>
      <p className="docs-lede">
        One field that searches your Mac and answers small questions. It opens
        ready to type, and dismisses when it loses focus — except while a system
        permission prompt is up.
      </p>

      <h2>Launching apps</h2>
      <p>
        Type to fuzzy-search your applications and press Return to launch. If
        the app is already running, its per-app hotkey brings it forward and
        pressing again hides it.
      </p>

      <h3>Ranking that learns</h3>
      <p>
        Every choice is recorded locally, along with the exact query that led to
        it. A use adds a point to a score with a seven-day half-life, so what
        you pick daily outranks an old binge. Among matched apps that score acts
        as a bonus, and the app you last chose for the <em>exact</em> query you
        typed is pinned first — which is why <code>sa</code> learns Safari after
        a single pick.
      </p>
      <p>
        On an empty query you get your most-chosen apps, filled out with
        Spotlight&rsquo;s last-used dates. None of this leaves the machine.
      </p>

      <h2>What a search returns</h2>
      <p>
        Results merge in a fixed order: math and unit results first, then apps,
        then up to three contacts and five files once the query is long enough
        to be worth it.
      </p>

      <h3>Prefixes force one source</h3>
      <div className="docs-table-scroll">
        <table className="docs-table">
          <thead>
            <tr>
              <th>Prefix</th>
              <th>Searches</th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <td><code>/</code></td>
              <td>Files only.</td>
            </tr>
            <tr>
              <td><code>@</code></td>
              <td>Contacts only. Contacts results merge into ordinary searches once access has been granted here at least once.</td>
            </tr>
            <tr>
              <td><code>cal</code> or <code>today</code></td>
              <td>Today and tomorrow&rsquo;s agenda.</td>
            </tr>
            <tr>
              <td><code>clip</code></td>
              <td>Clipboard history.</td>
            </tr>
            <tr>
              <td><code>note</code></td>
              <td>Recent notes. <code>note term</code> searches note contents and offers to create one.</td>
            </tr>
            <tr>
              <td><code>snip</code></td>
              <td>Snippets. You can also just type a snippet&rsquo;s keyword.</td>
            </tr>
            <tr>
              <td><code>:</code></td>
              <td>Emoji, searching 1,765 names from the bundled Unicode database.</td>
            </tr>
            <tr>
              <td><code>ext</code></td>
              <td>Runs a WebAssembly extension. See <a href="/docs/extensions">Extensions</a>.</td>
            </tr>
          </tbody>
        </table>
      </div>

      <h2>Calculating and converting</h2>
      <p>
        Arithmetic, percentages, unit and time zone conversions, dates,
        colors and currency answer as you type, as a card at the top of the
        results: <code>18% tip on 65</code>, <code>5 km in mi</code>,{' '}
        <code>3pm Lisbon in Tokyo</code>, <code>days until christmas</code>.
        Return copies the answer. See <a href="/docs/calculator">The
        calculator</a> for everything it understands.
      </p>

      <h2>Today&rsquo;s agenda</h2>
      <p>
        <code>cal</code> shows Today and Tomorrow. Select a meeting and press
        Return to join from its meeting link, or open it in Calendar.
      </p>

      <h2>Aliases and quicklinks</h2>
      <p>
        An <strong>alias</strong> maps a word to an app name and ranks that app
        first — <code>gh</code> for GitHub Desktop, say.
      </p>
      <p>
        A <strong>quicklink</strong> is a named URL with an optional{' '}
        <code>{'{query}'}</code> slot, so <code>google volant launcher</code>{' '}
        opens the search. Quicklinks accept http, https, mailto, and validated{' '}
        <code>shortcuts://run-shortcut</code> URLs — see{' '}
        <a href="/docs/shortcuts">Apple Shortcuts</a>. Both live in{' '}
        <a href="/docs/configuration">config.json</a>.
      </p>
      <p>
        To add a quicklink without editing the file, type{' '}
        <code>new quicklink</code> (or <code>create quicklink</code>) and press
        Return. Give it a name and a URL, then press Return to save or Escape to
        go back. The name cannot repeat a quicklink, snippet keyword, alias, or
        built-in command, and the URL must use one of the schemes above. The
        quicklink is appended to <code>quicklinks</code> in config.json and
        works at once.
      </p>

      <h2>The footer tells you the action</h2>
      <p>
        The footer names the Return action for whichever row is selected.
        Command-Return runs the secondary action instead — revealing a file in
        Finder, or copying a contact&rsquo;s phone number.
      </p>
      <p>
        Click the Volant mark at the bottom left to see which version you are
        running and to send feedback, open this manual, read the changelog,
        check for updates, or open Settings.
      </p>

      <h2>Moving the window</h2>
      <p>
        Drag the wing in the search header to move Volant. The position is saved
        and recovered into a visible display when your screen arrangement
        changes.
      </p>
      <p>
        Snap guides align the launcher to the usable screen center and edges,
        with a 20-point inset and a 12-point capture distance, each axis
        resolving independently against the display holding the pointer. Hold
        Option during a drag to bypass both snapping and the guides.
      </p>

      <h2>Appearance</h2>
      <p>
        <code>appearance.scale</code> accepts 0.8 to 1.4 and{' '}
        <code>appearance.opacity</code> accepts 0.5 to 1.0 in your
        configuration.
      </p>

      <DocFooterNav {...adjacentDocs('launcher')} />
    </>
  );
}
