// oxlint-disable next/no-html-link-for-pages -- vinext 1.0.0-beta.5's next/link throws in the
// production build, leaving internal navigation dead. Plain anchors until fixed upstream.
import type { Metadata } from 'next';

import { adjacentDocs } from '../docs-nav';
import { DocFooterNav } from '@/components/doc-footer-nav';

export const metadata: Metadata = {
  title: 'System control — Volant docs',
  description:
    'Change volume, switch audio routes, list connected Bluetooth devices, and join Wi-Fi networks from the launcher.',
  alternates: { canonical: 'https://usevolant.com/docs/system-control' },
};

export default function SystemControl() {
  return (
    <>
      <p className="docs-breadcrumb">
        <a href="/docs">Docs</a> / System control
      </p>
      <h1>System control</h1>
      <p className="docs-lede">
        Volume, audio routes, Bluetooth, and Wi-Fi, all through public APIs
        inside the app sandbox. Keep your Mac awake or open System Settings from
        the keyboard. No Accessibility grant is needed.
      </p>

      <h2>Volume</h2>
      <p>
        Type <code>volume</code> or <code>vol</code> to see the volume commands
        and your current default output.
      </p>
      <div className="docs-table-scroll">
        <table className="docs-table">
          <thead>
            <tr>
              <th>Command</th>
              <th>Effect</th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <td>
                <code>volume up</code> / <code>volume down</code>
              </td>
              <td>Adjusts by five percentage points.</td>
            </tr>
            <tr>
              <td>
                <code>volume 40</code> or <code>volume 40%</code>
              </td>
              <td>Sets an exact level.</td>
            </tr>
            <tr>
              <td>
                <code>mute</code> / <code>unmute</code>
              </td>
              <td>Explicit actions, not a toggle.</td>
            </tr>
          </tbody>
        </table>
      </div>
      <p>
        Return applies the selected action and keeps the launcher open, so you
        can adjust repeatedly. An invalid percentage never produces an
        actionable row.
      </p>
      <p>
        Volume changes keep your existing mute state, and channels scale
        together to preserve balance. The level shown is read back from the
        hardware; it refreshes on a query or an action, not continuously while
        another app changes it. Outputs that do not support software volume —
        common on digital connections — are labeled as such and explained rather
        than silently failing.
      </p>
      <div className="docs-note">
        <p>
          <code>vol</code>, <code>volume</code>, <code>mute</code>, and{' '}
          <code>unmute</code> are reserved ahead of your aliases and quicklinks,
          so a Raycast import will tell you if it had to skip one of those
          names.
        </p>
      </div>

      <h2>Audio devices</h2>
      <p>
        <code>audio</code>, <code>output</code>, and <code>input</code> list
        eligible audio routes, and you can filter by name —{' '}
        <code>output airpods</code> or <code>audio input mac</code>. Your
        current input and output are marked independently, and switching one
        direction never changes the other.
      </p>
      <p>
        Switching re-resolves the device&rsquo;s stable identifier before
        acting, so a recycled system device ID cannot send audio somewhere
        unexpected. This does not connect disconnected Bluetooth headphones, and
        no recording ever happens.
      </p>

      <h2>Bluetooth</h2>
      <p>
        <code>bluetooth</code> or <code>bt</code> lists connected paired
        devices. This is not a complete inventory of every nearby or unpaired
        peripheral. Selecting a device opens Bluetooth Settings to manage it —
        Volant does not connect or disconnect devices itself.
      </p>

      <h2>Wi-Fi</h2>
      <p>
        <code>wifi</code> scans visible networks and filters by name. Your
        current network is marked, and duplicate access points sharing an SSID
        and security type collapse to the strongest signal. Scan results live
        only in memory, with a fifteen-second freshness window.
      </p>
      <p>
        Open and WPA/WPA2/WPA3 Personal networks can be joined directly, using a
        native secure field inside the launcher.{' '}
        <strong>Use Saved Password</strong> explicitly requests that
        SSID&rsquo;s password from your Keychain. Hidden and enterprise networks
        hand off to System Settings.
      </p>
      <p>
        Passwords are never stored in Volant&rsquo;s configuration, history, or
        logs, and a password you type manually is not silently saved to the
        Keychain.
      </p>

      <h2>Keep awake</h2>
      <p>
        Type <code>caffeinate</code> to keep your Mac and its display awake,
        optionally for a duration, such as <code>caffeinate 30m</code>. The
        display stays on and unlocked unless you turn off{' '}
        <strong>Keep display on and unlocked</strong> in Settings → General.
        Add <code>system</code> or <code>display</code> to choose for one
        session. The launcher shows the active state and offers Stop. This
        does not change your saved power settings.
      </p>
      <h2>System Settings</h2>
      <p>
        Search for a settings pane, such as Displays or Login Items, and press
        Return to open it. These are pane links, not a search through every
        individual macOS setting.
      </p>
      <h2>System commands</h2>
      <p>
        Search for <code>lock</code>, <code>sleep</code>, or{' '}
        <code>screen saver</code> to lock the screen, sleep the Mac or displays,
        or start the screen saver. Restart, Shut Down, and Log Out ask macOS to
        show its own confirmation dialog. The launcher hides before acting and
        reports failures. Lock Screen and Sleep Displays can have their own
        global shortcuts.
      </p>
      <h2>Permissions</h2>
      <p>
        Bluetooth uses its own sandbox entitlement and system consent. Reading
        Wi-Fi network <em>names</em> requires Location authorization on macOS —
        Volant requests that authorization but never requests coordinates and
        never starts location updates. Both are asked for on first use, and
        denying either produces guidance plus a System Settings action rather
        than a broken screen.
      </p>

      <DocFooterNav {...adjacentDocs('system-control')} />
    </>
  );
}
