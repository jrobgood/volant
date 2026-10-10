#!/bin/bash
# Ship a Volant release with one owner action: merging its release pull request.
#
#   Scripts/ship.sh 0.2.3            prepare, wait for the owner's merge, then publish
#   Scripts/ship.sh 0.2.3 --publish  publish an already-merged release PR (resume)
#
# Prepare builds from `release/<version>` (or a fresh branch from main), which must contain
# docs/releases/<version>.md and any website copy for the release. It sets the version and next
# build number, archives, notarizes and staples through Scripts/release.sh, and opens one pull
# request with the DMG, checksums, signed update feed and release record. It never merges.
#
# Publish runs only after the owner merges that pull request, and uses only the merged commit. It
# keeps the two-stage order: the first deploy serves the previous feed while the public download is
# verified, and only then does a second deploy serve the merged feed, verified byte for byte. It
# finishes by publishing the GitHub release the app's Changelog item opens and posting the
# verification on the pull request.
#
# All work happens in a temporary worktree, so the main checkout and its branch are untouched. A
# failure stops at that point and states what has and has not been published.
set -euo pipefail

VERSION="${1:-}"
MODE="${2:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && ( -z "$MODE" || "$MODE" == --publish ) ]] \
  || { echo "Usage: Scripts/ship.sh <major.minor.patch> [--publish]"; exit 64; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SITE="https://usevolant.com"
BRANCH="release/$VERSION"
STATE="nothing published"

step() { printf '\n==> %s\n' "$*"; }
fail() { printf '\nShip stopped: %s\nState: %s\n' "$*" "$STATE" >&2; exit 1; }
trap 'fail "command failed at line $LINENO"' ERR

# Pushes the worktree's branch, opens a pull request with the given title and body file, and
# prints its number.
open_pr() {
  git -C "$WT" push -q -u origin "$BRANCH"
  gh pr create --base main --head "$BRANCH" --title "$1" --body-file "$2" | sed 's#.*/##'
}

# Waits until the owner merges the pull request and prints the merge commit. A pull request closed
# without merging stops the release with nothing published.
wait_for_merge() {
  local pr="$1" state
  while true; do
    state="$(gh pr view "$pr" --json state -q .state 2> /dev/null || echo UNKNOWN)"
    case "$state" in
      MERGED) gh pr view "$pr" --json mergeCommit -q .mergeCommit.oid; return ;;
      CLOSED) fail "PR #$pr was closed without merging" ;;
    esac
    sleep 60
  done
}

# Builds the website at the worktree's checkout and deploys the Worker with the project's pinned
# Wrangler, printing its version ID. Install scripts are skipped: the prebuilt image binaries are
# already in the lockfile, and sharp's install check otherwise falls back to a failing source build.
deploy_site() {
  local label="$1" version
  rm -rf "$WT/website/dist"
  (cd "$WT/website" && npm ci --ignore-scripts --no-audit --no-fund --loglevel=error) > "$LOGS/npm-$label.log" 2>&1 \
    || fail "npm ci failed; see $LOGS/npm-$label.log"
  (cd "$WT/website" && npm run build) > "$LOGS/site-build-$label.log" 2>&1 || fail "website build failed; see $LOGS/site-build-$label.log"
  (cd "$WT/website" && npx --no-install wrangler deploy --config dist/server/wrangler.json) > "$LOGS/deploy-$label.log" 2>&1 \
    || fail "wrangler deploy failed; see $LOGS/deploy-$label.log"
  version="$(sed -n 's/.*Current Version ID: \([0-9a-f-]*\).*/\1/p' "$LOGS/deploy-$label.log" | head -1)"
  [[ -n "$version" ]] || fail "wrangler reported no Worker version; see $LOGS/deploy-$label.log"
  echo "$version"
}

# Fetches a public URL into a file, retrying while a deployment propagates, and succeeds only once
# the downloaded bytes satisfy the given check.
fetch_until() {
  local url="$1" out="$2" check="$3"
  for _ in $(seq 1 20); do
    if curl -fsSL -H 'Cache-Control: no-cache' -o "$out" "$url?ship=$RANDOM" && eval "$check"; then return 0; fi
    sleep 15
  done
  return 1
}

step "Preflight"
command -v jq > /dev/null || fail "jq is required"
gh auth status > /dev/null 2>&1 || fail "gh is not signed in"
(cd "$ROOT/website" && npx --no-install wrangler whoami 2>&1 | grep -q "You are logged in") || fail "wrangler is not signed in"
git -C "$ROOT" fetch -q origin
LOGS="$(mktemp -d "$ROOT/dist-release.ship-$VERSION.XXXXXX")"
WT="$LOGS/worktree"
gh release view "v$VERSION" > /dev/null 2>&1 && fail "GitHub release v$VERSION already exists"

if [[ -z "$MODE" ]]; then
  CURRENT="$(git -C "$ROOT" show origin/main:project.yml | sed -n 's/.*MARKETING_VERSION: "\(.*\)"/\1/p' | head -1)"
  BUILD="$(( $(git -C "$ROOT" show origin/main:project.yml | sed -n 's/.*CURRENT_PROJECT_VERSION: "\(.*\)"/\1/p' | head -1) + 1 ))"
  [[ "$(printf '%s\n%s\n' "$CURRENT" "$VERSION" | sort -V | tail -1)" == "$VERSION" && "$CURRENT" != "$VERSION" ]] \
    || fail "$VERSION is not newer than $CURRENT on main"
  if git -C "$ROOT" ls-remote --exit-code --heads origin "$BRANCH" > /dev/null; then
    git -C "$ROOT" merge-base --is-ancestor origin/main "origin/$BRANCH" || fail "$BRANCH is behind main; rebase it first"
    git -C "$ROOT" worktree add -q -B "$BRANCH" "$WT" "origin/$BRANCH"
  else
    git -C "$ROOT" worktree add -q -B "$BRANCH" "$WT" origin/main
  fi
  NOTES="docs/releases/$VERSION.md"
  [[ -s "$WT/$NOTES" ]] || fail "$NOTES is missing on $BRANCH; write the release notes first"
  OUT="$LOGS/release"
  echo "Preparing $VERSION build $BUILD over $CURRENT. Logs: $LOGS"

  step "Set version $VERSION build $BUILD"
  sed -i '' -e "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"$VERSION\"/" \
    -e "s/CURRENT_PROJECT_VERSION: \".*\"/CURRENT_PROJECT_VERSION: \"$BUILD\"/" "$WT/project.yml"
  sed -i '' "s/export const appVersion = '.*';/export const appVersion = '$VERSION';/" "$WT/website/components/site-chrome.tsx"
  git -C "$WT" diff --quiet || git -C "$WT" commit -q -am "Set version $VERSION build $BUILD"
  BUILT="$(git -C "$WT" rev-parse HEAD)"

  step "Archive, notarize and staple (Scripts/release.sh)"
  VOLANT_RELEASE_OUT="$OUT" "$WT/Scripts/release.sh" 2>&1 | tee "$LOGS/release.log"
  DMG="$OUT/updates/Volant-$VERSION.dmg"
  [[ -f "$DMG" && -f "$OUT/updates/appcast.xml" ]] || fail "release.sh produced no DMG or appcast"
  read -r -a SUBMISSIONS <<< "$(grep -oE 'id: [0-9a-f-]{36}' "$LOGS/release.log" | awk '!seen[$2]++ {printf "%s ", $2}')"
  SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
  SIZE="$(stat -f %z "$DMG")"

  step "Inspect the mounted DMG"
  MOUNT="$(mktemp -d)"
  hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT" "$DMG" > /dev/null
  APP="$MOUNT/Volant.app"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")" == "$VERSION" ]] || fail "DMG app version mismatch"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")" == "$BUILD" ]] || fail "DMG app build mismatch"
  ARCHS="$(lipo -archs "$APP/Contents/MacOS/Volant")"
  codesign --verify --deep --strict "$APP"
  xcrun stapler validate "$APP" > /dev/null
  [[ -L "$MOUNT/Applications" ]] || fail "DMG has no Applications link"
  hdiutil detach -quiet "$MOUNT"

  step "Open the release pull request"
  cp "$DMG" "$WT/website/public/updates/"
  echo "$SHA  Volant-$VERSION.dmg" >> "$WT/website/public/updates/SHA256SUMS"
  (cd "$WT/website/public/updates" && shasum -a 256 -c SHA256SUMS > /dev/null)
  cp "$OUT/updates/appcast.xml" "$WT/website/public/updates/appcast.xml"
  "$WT/build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update" --account volant --verify "$WT/website/public/updates/appcast.xml"
  cat >> "$WT/docs/release-quality.md" <<EOF

## $VERSION build $BUILD — $(date '+%B %-d, %Y')

**What's in it.** See the [release notes](releases/$VERSION.md).

**Build.** Built from \`${BUILT:0:7}\` on \`$BRANCH\` by \`Scripts/ship.sh\`.

- **Notarization:** Apple accepted app submission \`${SUBMISSIONS[0]:-unknown}\` and DMG submission \`${SUBMISSIONS[1]:-unknown}\`. Both were stapled and passed Gatekeeper as Notarized Developer ID.
- **Mounted DMG:** \`Volant.app\` $VERSION, build $BUILD, \`$ARCHS\`, valid deep strict signature, stapled, Applications link present.
- **DMG SHA-256:** \`$SHA\` ($SIZE bytes).
- **Feed:** the signed build-$BUILD appcast generated with this DMG passes \`sign_update --verify\`.

**Publishing.** After the owner merged this release, \`Scripts/ship.sh\` deployed the download while the previous feed stayed live, verified the public DMG, then deployed the feed and compared it byte for byte. Its results are posted on the release pull request.
EOF
  git -C "$WT" add -A
  git -C "$WT" commit -q -m "Publish Volant $VERSION"
  cat > "$LOGS/pr.md" <<EOF
## Problem
Volant $VERSION build $BUILD is notarized and stapled. The website and update feed still offer $CURRENT.

## Behavior
Everything for the release, in one pull request:
- **Version:** $VERSION, build $BUILD (\`project.yml\`, website \`appVersion\`).
- **Notes:** [\`$NOTES\`]($NOTES), plus any website copy committed on \`$BRANCH\`.
- **Download:** \`website/public/updates/Volant-$VERSION.dmg\` ($SIZE bytes) and its SHA-256 in \`SHA256SUMS\`.
- **Feed:** the exact signed appcast for build $BUILD.
- **Record:** the build section of \`docs/release-quality.md\`.

**Merging this pull request approves publication.** \`Scripts/ship.sh\` is waiting for the merge. It then deploys the download with the previous feed still live, verifies the public DMG, deploys the new feed, verifies it byte for byte, publishes the GitHub release, and reports back here.

## Validation
- Notarized, stapled and Gatekeeper-assessed by \`Scripts/release.sh\` (submissions \`${SUBMISSIONS[0]:-unknown}\`, \`${SUBMISSIONS[1]:-unknown}\`).
- Mounted DMG: $VERSION build $BUILD, \`$ARCHS\`, deep strict signature, stapled.
- \`shasum -a 256 -c SHA256SUMS\` and \`sign_update --verify\` on the appcast pass.

## Limitations
- Installed $CURRENT → $VERSION Sparkle upgrades and Intel hardware are not verified by this script.
EOF
  PR="$(open_pr "Release Volant $VERSION" "$LOGS/pr.md")"
  STATE="release PR #$PR open; nothing published"
  printf '\nRelease PR: https://github.com/mysticcoders/volant/pull/%s\nMerge it when its checks pass to publish. Waiting for the merge...\n' "$PR"
else
  PR="$(gh pr list --head "$BRANCH" --state merged --json number -q '.[0].number')"
  [[ -n "$PR" ]] || fail "no merged pull request from $BRANCH"
  BUILT=""
fi

MERGED="$(wait_for_merge "$PR")"
STATE="release PR #$PR merged; nothing deployed"
git -C "$ROOT" fetch -q origin
if [[ -d "$WT" ]]; then git -C "$WT" checkout -q --detach "$MERGED"; else git -C "$ROOT" worktree add -q --detach "$WT" "$MERGED"; fi
if [[ -n "$BUILT" ]]; then
  git -C "$WT" diff --quiet "$BUILT" "$MERGED" -- . ':(exclude)website' ':(exclude)docs' \
    || fail "main changed app sources before the merge, so the DMG no longer matches main; ship a new version"
fi
DMG="$WT/website/public/updates/Volant-$VERSION.dmg"
FEED="$WT/website/public/updates/appcast.xml"
[[ -f "$DMG" ]] || fail "the merged commit has no Volant-$VERSION.dmg"
SHA="$(awk -v f="Volant-$VERSION.dmg" '$2 == f {print $1}' "$WT/website/public/updates/SHA256SUMS")"
[[ "$(shasum -a 256 "$DMG" | awk '{print $1}')" == "$SHA" ]] || fail "merged DMG does not match SHA256SUMS"
grep -q "sparkle:shortVersionString>$VERSION<" "$FEED" || fail "merged appcast does not offer $VERSION"
PREVIOUS_FEED="$LOGS/previous-appcast.xml"
git -C "$WT" show "$MERGED^:website/public/updates/appcast.xml" > "$PREVIOUS_FEED"
PREVIOUS="$(sed -n 's/.*sparkle:shortVersionString>\([^<]*\)<.*/\1/p' "$PREVIOUS_FEED" | head -1)"

step "Stage 1: deploy the download with the $PREVIOUS feed still live"
cp "$FEED" "$LOGS/merged-appcast.xml"
cp "$PREVIOUS_FEED" "$FEED"
DEPLOY1="$(deploy_site stage1)"
git -C "$WT" checkout -q -- website/public/updates/appcast.xml
STATE="download deployed in Worker version $DEPLOY1; feed still on $PREVIOUS"
fetch_until "$SITE/" "$LOGS/home.html" "grep -q 'Volant-$VERSION.dmg' '$LOGS/home.html'" || fail "homepage does not offer $VERSION"
fetch_until "$SITE/updates/Volant-$VERSION.dmg" "$LOGS/public.dmg" "[[ \$(shasum -a 256 '$LOGS/public.dmg' | awk '{print \$1}') == $SHA ]]" \
  || fail "public DMG does not match the release"
xcrun stapler validate "$LOGS/public.dmg" > /dev/null
spctl --assess --type open --context context:primary-signature "$LOGS/public.dmg" 2> /dev/null
SIZE="$(stat -f %z "$LOGS/public.dmg")"

step "Stage 2: deploy the $VERSION feed"
cmp -s "$FEED" "$LOGS/merged-appcast.xml" || fail "could not restore the merged appcast"
DEPLOY2="$(deploy_site stage2)"
STATE="download and feed deployed (Worker $DEPLOY2); GitHub release not yet published"
fetch_until "$SITE/updates/appcast.xml" "$LOGS/live-appcast.xml" "cmp -s '$LOGS/live-appcast.xml' '$FEED'" \
  || fail "live feed does not match the merged appcast"
SIGN_UPDATE="$WT/build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
FEED_SIGNATURE="byte-for-byte match with the merged, signed appcast"
if [[ -x "$SIGN_UPDATE" ]]; then
  "$SIGN_UPDATE" --account volant --verify "$LOGS/live-appcast.xml"
  FEED_SIGNATURE="$FEED_SIGNATURE; Sparkle \`sign_update --verify\` passes"
fi
for path in / /docs "/updates/Volant-$VERSION.dmg" "/updates/Volant-$PREVIOUS.dmg"; do
  [[ "$(curl -s -o /dev/null -w '%{http_code}' -I "$SITE$path")" == 200 ]] || fail "$SITE$path did not return 200"
done

step "Publish the GitHub release"
RELEASE_URL="$(gh release create "v$VERSION" "$DMG" --target "$MERGED" --title "Volant $VERSION" \
  --notes-file "$WT/docs/releases/$VERSION.md" --latest | tail -1)"
STATE="fully published"

cat > "$LOGS/report.md" <<EOF
**Published by \`Scripts/ship.sh\`.**

- **Stage 1:** Worker version \`$DEPLOY1\` served the download while the $PREVIOUS feed stayed live. The homepage offers \`Volant-$VERSION.dmg\`; the public DMG (HTTP 200, $SIZE bytes) matched SHA-256 \`$SHA\`, passed stapler validation and passed Gatekeeper.
- **Stage 2:** Worker version \`$DEPLOY2\` serves the $VERSION feed: $FEED_SIGNATURE.
- **Pages:** \`/\`, \`/docs\`, and the $VERSION and $PREVIOUS DMGs return 200.
- **GitHub release:** $RELEASE_URL
- **Still unverified:** installed $PREVIOUS → $VERSION Sparkle upgrades, and Intel hardware.
EOF
gh pr comment "$PR" --body-file "$LOGS/report.md" > /dev/null

trap - ERR
git -C "$ROOT" worktree remove --force "$WT"
git -C "$ROOT" branch -D "$BRANCH" > /dev/null 2>&1 || true
printf '\nShipped Volant %s.\n' "$VERSION"
cat "$LOGS/report.md"
