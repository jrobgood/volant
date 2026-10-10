# Volant release and screenshot quality

## Decisions — 2026-09-14

- The launcher wing, selected result and Herdr strip follow the color theme's accent. The default System theme uses the macOS accent color; the Volant theme keeps the coral wing brand with separate light/dark values, and marketing renders still use the AccentColor asset. See [color themes](color-themes.md).
- Herdr’s chevron persists the expanded overview in app preferences. It shows project, provider, pane ID, and textual status, with attention first. The overview is bounded and scrollable. Default stays compact; disclosure does not focus or send input to an agent.
- Marketing must use captures of the real SwiftUI launcher with fictional data. `tools/render-marketing.sh` uses the exported app’s Assets.car and the same source views. A hand-built HTML approximation had drifted from the product; native captures prevent that mismatch.
- Sparkle 2.10.0 is pinned. Use its Installer and Downloader XPC services; the main app still has no outgoing-network entitlement. Export the archive using Developer ID so all Sparkle helpers are re-signed. See [Sparkle sandbox integration](https://sparkle-project.org/documentation/sandboxing/).
- Update private key is in login Keychain under account `volant`; only its public key is in project.yml. Do not regenerate or rotate it casually. Back it up securely before the first public release; never commit it.

## Release procedure

A release needs one owner action: merging its release pull request.

1. **Notes and copy.** On a `release/<version>` branch from current `main`, write `docs/releases/<version>.md` (the GitHub release body the app's Changelog item opens). Commit any website copy, feature badges, documentation notices and `docs/marketing-claims.md` changes the release makes true. Push the branch.
2. **Ship.** Run `Scripts/ship.sh <version>`. It sets `MARKETING_VERSION` and the next `CURRENT_PROJECT_VERSION` (never reused), runs `Scripts/release.sh` to archive, export, notarize and staple the app and DMG and sign the appcast, inspects the mounted DMG, and opens one pull request with the DMG, `SHA256SUMS`, the signed appcast and this document's build record. It never merges.
3. **Owner merges.** Merging the release pull request after its checks pass approves publication. The waiting script then works only from the merged commit: it deploys the download while serving the previous feed, verifies the public DMG's SHA-256, staple and Gatekeeper result, deploys the merged feed and compares it byte for byte, checks the pages and both DMGs, publishes the GitHub release with the DMG, and posts the results on the pull request. If the script was interrupted, `Scripts/ship.sh <version> --publish` resumes from the merged pull request.

Every step stops on failure and states what is and is not published; the new feed is never served before its download is verified. Each script run uses its own `dist-release.ship-*` folder and a temporary worktree, leaving the main checkout untouched.

**One-time setup.** Store the App Store Connect API key used for earlier releases as the `volant` notarization profile: `xcrun notarytool store-credentials volant --key ~/.appstoreconnect/private_keys/AuthKey_SCV5964PL2.p8 --key-id SCV5964PL2 --issuer <issuer-ID>`. `Scripts/release.sh` also still accepts `VOLANT_NOTARY_KEY`, `VOLANT_NOTARY_KEY_ID` and `VOLANT_NOTARY_ISSUER`. Allow Keychain access for the Developer ID key and the Sparkle key (account `volant`) when first prompted so later runs are unattended. `gh` and `wrangler` must be signed in.

Not automated: an installed previous build updating through Sparkle (decline/cancel, relaunch, preserved notes and config) and Intel hardware checks. A signed appcast alone does not establish a working update installation.

## Evidence

- Developer ID archive and export succeeded on this Mac. Export includes Sparkle’s framework, installer/downloader XPC services, updater, and autoupdate helper.
- SwiftLint passed. `tools/check-launcher.sh` passed in light and dark appearances, including actual non-activating panel typing/clicks, repeated summon, selection, and connectivity fixtures.
- Inspected native light/dark marketing renders with expanded fictional Herdr panes and coral accents.
- Website production build and TypeScript check passed. Desktop and 390px mobile renders inspected.
- Signed `dist/Volant-0.1.0-unnotarized.dmg` is a development delivery, not a public release. Notarization profile `vey` is absent. This initial attempt was blocked on credentials; the public releases below resolved it.

## Remaining work

- Notarization completed for build 2; see the release evidence below.
- Installed signed-app live smoke test: OS appearance switching, Herdr disclosure click/persistence, Settings/menus, updater prompt, larger text and minimum launcher scale. Render fixtures do not establish these.
- Two-version Sparkle installation verified on October 7, 2026: the owner updated two Macs from 0.1.5 to 0.2.0 through Sparkle. See the 0.2.0 entry.
- Intel hardware verification remains outstanding. Inspect archive architecture before making hardware support claims.

## Automation

Release signature/entitlement/notarization/stapling checks are automated in `Scripts/release.sh`; launcher interaction fixtures are automated through `Scripts/test.sh`. Visual review and installed updater smoke tests remain manual. No CI release upload is configured.

Additional artifact checks: the mounted DMG contains `Volant.app` and the `/Applications` symlink. The executable has `x86_64 arm64` slices; mounted app signature and DMG checksum validation passed. Local Sparkle appcast generation succeeded using Keychain account `volant`, producing an Ed25519 signature for the DMG. This preview appcast is intentionally not hosted. Mobile page width equals scroll width (390px), and the full-size screenshot link was followed successfully.

The local preview appcast was also signed as XML with Sparkle `sign_update` and its embedded signature verified successfully. Release script now performs both steps after generating the DMG enclosure signature. SHA-256 of the current unnotarized DMG: `5927d1d98d77025ecd2a8d9a10829554b2ab6b461075b930ce51ef0663080ce5`.


## Public DMG — 2026-09-14

The owner requested that Volant be offered as a packaged DMG. Released **0.1.0, build 2** to `https://usevolant.com/updates/Volant-0.1.0.dmg`, with the signed Sparkle feed at `/updates/appcast.xml` and checksums at `/updates/SHA256SUMS`. The website now has Download for Mac links and installation instructions, labeled as an early release.

- Apple accepted the app submission `9f38d346-532f-4d93-b6c1-f15e99024f4b` and DMG submission `289a4aee-718a-4891-abd4-8db1ec813a90`.
- Both artifacts were stapled, validated, and accepted by Gatekeeper as Notarized Developer ID.
- The public DMG downloaded with HTTP 200 and SHA-256 `a636cd7ab4259ead34bbf5c381d7382dba12c15573979ea771d663785dae2cd2`, matching the release exactly. Public appcast matches the locally signed/verified XML byte-for-byte. Both use revalidation rather than a stale long-lived cache.
- Website production build, TypeScript, page lint, and desktop/mobile download-section inspection passed. Public download links were verified in the browser.
- Cloudflare Worker version: `cd45f136-3ef1-4483-b70b-dbd65a5a74b5`.
- Release source/output: `dist-release.HbFKCk/`. Notarization used the existing same-team App Store Connect API key already used by GeoKids, without exporting private credentials. The earlier missing Keychain profile is no longer a blocker.

Lessons: checking only the old `vey` profile missed an existing reusable Apple API credential. Check established same-team release configuration before declaring notarization blocked. On this macOS, `codesign -dv` did not show Authority lines; `-dvvv` does. Save signing output before inspecting it, avoiding an early-closing pipeline in a pipefail script. Both preflight authentication and the corrected signature check are now automated.

Remaining verification: installed two-version Sparkle upgrade, installed-app live appearance/accessibility checks, and Intel hardware smoke test. A notarized universal package is not evidence that those tests passed.

## Public 0.1.1 — 2026-09-14

Build 3 adds active-work focus retention and remembered window placement by dragging the wing. Native isolated panel checks passed in light/dark, and interactive dragging and appearance were inspected. Apple accepted app submission `a35033b4-5b78-4bac-b77e-a971a35e9014` and DMG submission `a2de573a-ecb2-4b63-9440-81f7e277a392`. Release output: `dist-release.IsCYA6/`.

The public DMG SHA-256 is `78444a229e185be884741ef1a9c11c929349aa02631d6ebc2e7fa2cc2e5c6370`, matching the local artifact. The downloaded artifact passed stapler validation and Gatekeeper (Notarized Developer ID); the published appcast matches the signed local feed byte-for-byte. Website build, TypeScript, page lint and desktop/390px mobile inspection passed. Cloudflare deployment: `edc2b78b-084f-4a71-91cc-9e6ead8895ee`.

The repository is public under MIT. The website highlights that in its hero, main copy, FAQ and footer, with GitHub and Mystic Coders X links. Footer headline: “Move faster with Volant.” The installed two-version Sparkle upgrade and Intel hardware checks remain outstanding.

## Local Settings test DMG — 0.1.2 build 4

`dist-release.ykah5E/updates/Volant-0.1.2.dmg` contains the expanded Settings, compact menu and app shortcut/alias editor. Archive/export, Apple notarization, stapling, Gatekeeper and signed appcast verification passed. It has not replaced the public 0.1.1 feed. See [Settings quality](settings-quality.md) for native UI evidence and installed hotkey verification still required. An earlier local candidate in `dist-release.3pKrno` is superseded; deliver only `ykah5E`.


## 0.1.3 build 5 — September 15, 2026

Prepared from release version commit `82590f3`, incorporating main `683c24e`. Includes the latest Settings/shortcuts, emoji grid, Caffeinate cup, window positioning and translation UI. Output: `dist-release.emndwF/`.

Apple accepted app submission `823e6314-1f14-4350-bb1e-762f86d4a225` and DMG submission `124f624e-bbd3-4952-9741-5cca146f5181`. Both artifacts were stapled and passed Gatekeeper as Notarized Developer ID. Mounted app signature/staple, version/build, `x86_64 arm64` slices and Applications symlink verified. SHA-256: `eb7785cefa3a8f1288fc272c77bfa42c01bbf8acff9fc873c376efc8ca05452b`. Generated Sparkle enclosure metadata matches build 5, version 0.1.3 and the DMG size; signed appcast verification passed.

Local diff-selected native checks passed; UI fixtures correctly skipped for this version/download-only change. Feature UI verification is recorded in the earlier feature PRs. Website production build, TypeScript and page lint passed.

Publish in two stages: first the new DMG and website links while retaining the old feed, verify public delivery, then publish the signed build-5 appcast. Existing public DMGs and checksums remain available. Download published through Cloudflare version `bdb53f1a-09b7-41b8-a2ee-94f584b23bf6` after PR #20 passed its native/scope/PR gate checks. The live homepage offers 0.1.3. A fresh public download matched the SHA-256 above and passed stapler/Gatekeeper. The follow-up publishes the exact already-verified signed build-5 appcast; public feed verification follows activation.

Remaining limits: no installed two-version Sparkle upgrade, Intel hardware smoke test, or signed installed-app Apple translation/model-download verification. This publication does not replace the owner's running app or interrupt its Caffeinate session.

## 0.1.4 build 6 — September 18, 2026

Release includes merged launcher window/status fixes and global app-shortcut delivery fixes. The owner confirmed physical shortcuts, Settings handoff, dragging and focus-loss dismissal. PR #53 passed 103 native tests, the full headless Tart UI suite and inspected light/dark fixtures. The version-only release branch passed its scoped checks; unchanged UI fixtures were correctly skipped.

Archive and export, app and DMG notarization/stapling, deep strict signature verification, Gatekeeper and signed Sparkle appcast verification passed. DMG SHA-256: `8df71edca02de2625c548b3a36bebeca6aaf4b16c94dd60633c06b45579af4f3`. Publish the DMG first, verify public delivery, then activate the signed build-6 feed. Preserve the previously deployed documentation site and all old DMGs.

Sparkle's official sandboxing documentation confirms its XPC services belong inside the framework, with an unsandboxed Downloader by default. The previous untracked timeout report does not establish an entitlement or service-name defect; do not rename services or broaden application permissions based on that hypothesis. End-to-end updater verification is tracked separately from signing/feed checks.

Public DMG delivery verified after Cloudflare deployment `0f92328a-cb8f-4783-8161-4f6ee095a572`: downloaded bytes matched the checksum above, and the downloaded DMG passed staple validation and Gatekeeper. The deployed documentation pages were preserved using an isolated copy of their already-published source. The next change activates the exact signed appcast generated alongside this DMG.

Final publication: signed build-6 feed activated in Cloudflare deployment `ff799860-de5d-4823-b1b5-747976f07e8c`. The public feed matched the generated file byte-for-byte and passed Sparkle signature verification. Live homepage version/download links and `/docs` returned correctly. Release PRs #54 and #55 passed required workflow checks before merging.

A disposable headless macOS 15.7.7 VM installed the original notarized 0.1.1 app with Gatekeeper enabled. Its stock Sparkle Downloader fetched the public feed successfully: HTTP 200, 1,121 response bytes, 227 ms transaction duration. The earlier timeout did not reproduce, so service renaming or broader network entitlements are not justified. VM AppleEvent UI inspection timed out, so update acceptance, replacement/relaunch and retained-data checks are **not verified**. Next release-quality task: make the headless updater UI fixture reliable and complete an old-to-current upgrade with fictional notes/config. Do not equate feed/network success with a completed upgrade.

## 0.1.5 build 7 — October 3, 2026

Release includes iCloud settings sync code (#104), Finder and CoreServices apps in the app list (#105), human-readable timezone answers (#106–#108), the two-sided calculator card (#109), relative-day times (#110) and GeoNames city lookup (#111). Each feature PR passed hosted native, UI and PR gate checks. The owner chose to ship the iCloud switch as-is: release signing has no provisioning profile yet, so this build carries no iCloud entitlement and the switch reports iCloud as unavailable.

Built from `release/0.1.5` (version-only commit on main `bedbf0e`). Output: `dist-release.qgFDxi/`. Notarization used App Store Connect API key `SCV5964PL2` at the owner's direction. Apple accepted app submission `fd5b8c8e-5e90-408e-a1ef-d77d4a18f69b` and DMG submission `5dd3ed1b-3b5e-43e2-8880-ad28a5a0c4cc`. Both were stapled and passed Gatekeeper as Notarized Developer ID. The mounted DMG contains `Volant.app` (0.1.5, build 7, `x86_64 arm64`, valid deep strict signature, stapled, bundled city table, no iCloud or network-client entitlement) and the Applications symlink. DMG SHA-256: `022d447abd30cb87f6ae2b13f2e9e4e875117f4fa62280e174dc55b3a62c3400`. The signed appcast references build 7 and the DMG length.

Publish in two stages as before: DMG, checksums and website first, verify public delivery, then activate the signed build-7 feed.

Public DMG delivery verified after Cloudflare deployment `41b96146-f281-4a01-b448-eba3e428dc68` (run by the owner): the homepage offers 0.1.5 and `/docs/launcher` serves the time-conversion section. The downloaded DMG (HTTP 200, 8,359,368 bytes) matched the SHA-256 above, passed stapler validation and Gatekeeper (Notarized Developer ID), and `getvolant.com` still redirects. The public feed remained on 0.1.4 until the follow-up activates the exact signed build-7 appcast.

Final publication: signed build-7 feed activated in Cloudflare deployment `aba0225d-8607-4ab2-aac9-4998ff522012` (run by the owner). The public feed (HTTP 200, `max-age=0, must-revalidate`) matched the generated file byte-for-byte, reports version 0.1.5 build 7, and passed Sparkle `sign_update --verify`. The homepage, `/docs`, and the 0.1.5 and 0.1.4 DMGs returned 200. Release PRs #112 and #113 passed required workflow checks before merging. As before, an installed 0.1.4 → 0.1.5 upgrade, the Intel hardware smoke test and working iCloud sync (no entitlement in this build) remain unverified.

## 0.2.0 build 8 — October 7, 2026

Release includes everything merged since 0.1.5:

- **Calculator:** the expanded calculator, #137–#149.
- **Currencies:** about 160 fiat currencies through ExchangeRate-API behind ECB, #146.
- **Crypto:** keyless CoinGecko prices, #138.
- **Themes:** color themes, Raycast theme import and a themed Notes editor, #147, #148, #150.
- **System commands:** lock, sleep, screen saver, restart, shut down and log out, #102.
- **Launcher:** steadier launcher typing, #144.
- **Memory:** reductions, #155, #156.
- **iCloud:** settings sync enabled by the key-value entitlement and Developer ID profile signing, #153.

The owner chose 0.2.0 for the iCloud sync.

**Profile fix.** The first Developer ID run failed before building: the "Volant Developer ID" profile created on October 1 listed only the March 2024 Developer ID Application certificate (`1CA0…D900`), while this Mac signs with the April 22, 2026 certificate (`2AFC…A6D2`), which also signed every published DMG. The owner regenerated the profile with the April 22 certificate (UUID `282891c4-d009-44b6-a929-e10b1f637ea5`). The team holds three Developer ID Application certificates, all expiring February 1, 2027; the March 2024 and April 11, 2026 ones are unused. Create a new certificate and add it to the profile before then.

**Build.** Built from `main` at `d9b6dbc` (#157, version-only). Output: `dist-release.DNIqft/`.

- **Notarization:** used App Store Connect API key `SCV5964PL2`. Apple accepted app submission `e3ab46a4-2c31-42ab-a45c-3bbb317c6f00` and DMG submission `cd5daa84-4ca6-4514-9bd1-21ebdb7b11b5`. Both were stapled and passed Gatekeeper as Notarized Developer ID.
- **Mounted DMG:** contains `Volant.app` (0.2.0, build 8, `x86_64 arm64`, valid deep strict signature, stapled, sandboxed, iCloud key-value and loginwindow Apple Events entitlements, embedded provisioning profile, no network-client entitlement) and the Applications symlink.
- **DMG SHA-256:** `a2fb27d792b8c309e72ec597faa449f01c9710c97b3c3dc75eae607abc74c03e`.
- **Appcast:** the signed appcast references build 8 and the DMG length (12,261,884 bytes).

An earlier local test build of the same code, still labeled 0.1.5 build 7 (`dist-release.2gNQDA/`, DMG submission `b296668c-8808-4af4-be60-c5588d004a11`), was used only to try iCloud sync on a second Mac and must never be published.

**Publishing.** Publish in two stages as before: DMG, checksums and website first, verify public delivery, then activate the signed build-8 feed.

**Verified by the owner.** iCloud settings sync between two Macs on the same Apple Account, theme switching, and the system actions in the installed app.

**Unverified.** Intel hardware, and iCloud quota and account-change notifications.

Public DMG delivery verified after Cloudflare Worker deployment `c71b8169-4bb7-4cac-9bdd-48a4616605bb` (run by the owner from #158):

- **Homepage:** offers `Volant-0.2.0.dmg` and the New in 0.2.0 sections.
- **Download:** HTTP 200, 12,261,884 bytes. It matched the SHA-256 above, passed stapler validation and passed Gatekeeper as Notarized Developer ID.
- **Pages:** `/docs`, `/docs/calculator`, `/docs/system-control` and `/docs/privacy-and-security` returned 200.
- **Redirect:** `getvolant.com` still redirects to usevolant.com.
- **Feed:** the public feed (`max-age=0, must-revalidate`) remained on 0.1.5 build 7 until the follow-up activates the exact signed build-8 appcast. That appcast passes `sign_update --verify` and references `Volant-0.2.0.dmg`, 12,261,884 bytes.

Final publication: the signed build-8 feed was activated in Cloudflare Worker deployment `8250b031-a1ab-4eff-8700-b096bcbe2047` (run by the owner from #159).

- **Feed:** the public feed (HTTP 200, `max-age=0, must-revalidate`) matched both the committed file and the release output byte-for-byte. It reports version 0.2.0 build 8 and passed Sparkle `sign_update --verify`.
- **Pages and downloads:** the homepage, `/docs`, and the 0.2.0 and 0.1.5 DMGs returned 200.
- **Release PRs:** #157, #158 and #159 passed required workflow checks before merging.
- **Still unverified:** Intel hardware.

Installed upgrade verified by the owner after activation: two Macs running 0.1.5 updated to 0.2.0 through Sparkle, relaunched, and worked normally. This is the first completed two-version Sparkle upgrade for Volant.

## 0.2.1 build 9 — October 8, 2026

**The fix.** 0.2.1 fixes a 0.2.0 regression that left the app list empty on some Macs (#162). The app index searched the whole computer, so Spotlight waited on every mounted volume. On the owner's Mac (an SMB share from another Mac, Xcode's CoreDevice DeviceFS and simulator images), gathering never finished. The launcher and Settings showed no applications and no error, while the same build worked on another Mac. The query now searches only the application folders and reads results during gathering.

**Probes on the affected Mac.** Exact predicate and filter, run as a sandboxed ad-hoc app bundle:

| Scope | Result |
| --- | --- |
| Whole computer | Never finished within 40 s |
| Application folders | About 1 s, 198 apps |

A development build with the fix, installed on the owner's Mac, was used before release.

**Build.** Built from `main` at `20adedf` (#163, version-only). Output: `dist-release.dyZ8UO/`.

- **Notarization:** used App Store Connect API key `SCV5964PL2`. Apple accepted app submission `a4bf4d92-72f0-4284-85dc-01e7273a8165` and DMG submission `89b518ed-b1ea-413d-bb9d-ac57303987af`. Both were stapled and passed Gatekeeper as Notarized Developer ID.
- **Mounted DMG:** `Volant.app` 0.2.1, build 9, `x86_64 arm64`, valid deep strict signature, stapled, sandboxed, iCloud key-value and loginwindow entitlements, embedded provisioning profile.
- **DMG SHA-256:** `eb064c2689bc643d4059ef61903539893f3b3d082201b593e1e3535e580e8f89` (12,262,988 bytes).

**Publishing.** In two stages: DMG, checksums and website first, then the signed build-9 feed.

Public DMG delivery verified after Cloudflare Worker deployment `00f07ab2-5ced-46b3-a85d-b34d9dc3f69c` (run by the owner from #164):

- **Homepage:** offers `Volant-0.2.1.dmg`.
- **Download:** HTTP 200, 12,262,988 bytes. It matched the SHA-256 above, passed stapler validation and passed Gatekeeper as Notarized Developer ID.
- **Pages:** `/docs`, `/docs/agents` and the 0.2.0 DMG returned 200.
- **Feed:** the public feed stayed on 0.2.0 build 8 until the signed build-9 appcast (passes `sign_update --verify`, 12,262,988 bytes) is activated.

Final publication: the signed build-9 feed was activated in Cloudflare Worker deployment `6484610c-0027-4926-8a2f-2a51e7c6cc54` (run by the owner from #165).

- **Feed:** the public feed (HTTP 200, `max-age=0, must-revalidate`) matched both the committed file and the release output byte-for-byte. It reports version 0.2.1 build 9 and passed Sparkle `sign_update --verify`.
- **Pages and downloads:** the homepage, `/docs`, and the 0.2.1 and 0.2.0 DMGs returned 200.
- **Release PRs:** #162 through #165 passed required workflow checks before merging.
- **Still unverified:** installed 0.2.0 → 0.2.1 Sparkle upgrades, and Intel hardware.

## 0.2.2 build 10 — October 9, 2026

**What's in it.**

- **Volant menu:** the version header, feedback, manual, changelog, Check for Updates, About, Settings and Quit (#167). Approved by the owner on an installed build.
- **Footer and fades:** list edge fades, and results scrolling under a translucent footer (#167), with a measured show-through guard.
- **Herdr footer status:** "Herdr: N waiting" replaces the strip under the search field (#168). Owner-approved after testing with a remote machine. The fix for scroll stutter while a remote loads is in the same PR: Herdr change announcements went from 197 to 14 over 10 refresh ticks, and the launcher view no longer observes the agents model.
- **Notes editor theme colors:** re-landed (#169). #152's squash merge had reverted #150, so 0.2.0 and 0.2.1 shipped without them.

**Build.** Built from `main` at `e45903c` (#170, version-only). Output: `dist-release.nqK5Xo/`.

- **Notarization:** used App Store Connect API key `SCV5964PL2`. Apple accepted app submission `2780c849-cd20-4e02-bead-a662d68523dc` and DMG submission `8613d058-b6b2-49db-b748-cd53dd820ab2`. Both were stapled and passed Gatekeeper as Notarized Developer ID.
- **Mounted DMG:** `Volant.app` 0.2.2, build 10, `x86_64 arm64`, valid deep strict signature, stapled, sandboxed, iCloud key-value and loginwindow entitlements, embedded provisioning profile.
- **DMG SHA-256:** `1794d625444d1fb77bbed54d4e079fa633fa1365525f7ce7b762c691b0cbb228` (12,450,153 bytes).

**Publishing.** In two stages: DMG, checksums and website first, then the signed build-10 feed.

Public DMG delivery verified after Cloudflare Worker deployment `2ea13735-f621-48e5-b76d-3bad30886f79` (run by the owner from #171):

- **Homepage:** offers `Volant-0.2.2.dmg`.
- **Download:** HTTP 200, 12,450,153 bytes. It matched the SHA-256 above, passed stapler validation and passed Gatekeeper as Notarized Developer ID.
- **Docs:** `/docs/agents` shows "Herdr in the footer".
- **Feed:** stayed on 0.2.1 build 9 until the signed build-10 appcast (passes `sign_update --verify`, 12,450,153 bytes) is activated.

Final publication: the signed build-10 feed was activated in Cloudflare Worker deployment `3de4348f-8f1e-42d6-9efd-50831b1bf24a` (run by the owner from #172).

- **Feed:** the public feed (HTTP 200, `max-age=0, must-revalidate`) matched both the committed file and the release output byte-for-byte. It reports version 0.2.2 build 10 and passed Sparkle `sign_update --verify`.
- **Pages and downloads:** the homepage, `/docs`, and the 0.2.2 and 0.2.1 DMGs returned 200.
- **Release PRs:** #167 through #172 passed required workflow checks before merging.
- **Still unverified:** installed 0.2.1 → 0.2.2 Sparkle upgrades, and Intel hardware.

## 0.2.3 build 11 — October 9, 2026

**What's in it.** See the [release notes](releases/0.2.3.md).

**Build.** Built from `450f1e9` on `release/0.2.3` by `Scripts/ship.sh`.

- **Notarization:** Apple accepted app submission `0338caa3-8c56-4e92-89b5-7b54526f814a` and DMG submission `a214fbd4-0acb-4ab2-b237-1d59649bb93d`. Both were stapled and passed Gatekeeper as Notarized Developer ID.
- **Mounted DMG:** `Volant.app` 0.2.3, build 11, `x86_64 arm64`, valid deep strict signature, stapled, Applications link present.
- **DMG SHA-256:** `7d6e45cc58beeedad3dd2b442a8ec7312352fc20836182b499b797825977015d` (12463165 bytes).
- **Feed:** the signed build-11 appcast generated with this DMG passes `sign_update --verify`.

**Publishing.** After the owner merged this release, `Scripts/ship.sh` deployed the download while the previous feed stayed live, verified the public DMG, then deployed the feed and compared it byte for byte. Its results are posted on the release pull request.

## 0.2.4 build 12 — October 9, 2026

**What's in it.** See the [release notes](releases/0.2.4.md).

**Build.** Built from `cd8c04e` on `release/0.2.4` by `Scripts/ship.sh`.

- **Notarization:** Apple accepted app submission `36619658-f48c-4ba9-8f3f-9d249a73918f` and DMG submission `117bbf31-5dac-4c21-bcb4-602f18d8a365`. Both were stapled and passed Gatekeeper as Notarized Developer ID.
- **Mounted DMG:** `Volant.app` 0.2.4, build 12, `x86_64 arm64`, valid deep strict signature, stapled, Applications link present.
- **DMG SHA-256:** `5f7ec0eab6eb672242e67d8286c75b3c8e580ff42a23719a2fdb3f242cd52898` (12691634 bytes).
- **Feed:** the signed build-12 appcast generated with this DMG passes `sign_update --verify`.

**Publishing.** After the owner merged this release, `Scripts/ship.sh` deployed the download while the previous feed stayed live, verified the public DMG, then deployed the feed and compared it byte for byte. Its results are posted on the release pull request.
