#!/bin/bash
# Builds the end-to-end harness for the input helper: a sandboxed container named Volant, with
# Volant's bundle identifier, around the real VolantInputHost.xpc built by xcodebuild. Both are
# signed with the Developer ID used for releases (hardened runtime; not notarized), because the
# helper accepts only that team's com.mysticcoders.volant. Building signs but never runs it: the
# harness runs only in a disposable Tart clone (tools/input-host-e2e/run-vm.py).
#
# Usage: build.sh <out-dir>
set -euo pipefail
cd "$(dirname "$0")/../.."
source tools/core-module.sh
out=${1:?usage: build.sh <out-dir>}
identity=${VOLANT_SIGN_IDENTITY:-'Developer ID Application: Mystic Coders, LLC (REMBT6JY4N)'}
mkdir -p "$out"

xcodegen generate --quiet
xcodebuild -project Volant.xcodeproj -scheme Volant -configuration Release -derivedDataPath "$out/derived" \
    -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO >"$out/xcodebuild.log" 2>&1 || {
    tail -40 "$out/xcodebuild.log" >&2
    exit 1
}
built="$out/derived/Build/Products/Release/Volant.app/Contents/XPCServices/VolantInputHost.xpc"

bundle="$out/Volant.app"
rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/XPCServices"
ditto "$built" "$bundle/Contents/XPCServices/VolantInputHost.xpc"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleExecutable</key><string>Volant</string>
<key>CFBundleIdentifier</key><string>com.mysticcoders.volant</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleName</key><string>Volant</string>
<key>CFBundleDisplayName</key><string>Volant</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.0.0</string>
<key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
mkdir -p "$out/src"
cp tools/input-host-e2e/harness.swift "$out/src/main.swift"
swiftc -O -target "$(uname -m)-apple-macosx15.0" "${VOLANT_CORE_FLAGS[@]}" "$out/src/main.swift" \
    Volant/Dictation/InputHostConnection.swift Volant/HotKeys/HotKeyCenter.swift Volant/HotKeys/KeyCombo.swift \
    Volant/HotKeys/DictationEscapeKey.swift -o "$bundle/Contents/MacOS/Volant"

cat > "$out/helper.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict/></plist>
PLIST
cat > "$out/app.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>com.apple.security.app-sandbox</key><true/>
</dict></plist>
PLIST
codesign --force --sign "$identity" --options runtime --timestamp=none \
    --entitlements "$out/helper.entitlements" "$bundle/Contents/XPCServices/VolantInputHost.xpc"
codesign --force --sign "$identity" --options runtime --timestamp=none \
    --entitlements "$out/app.entitlements" "$bundle"
codesign --verify --deep --strict "$bundle"
codesign -d -r- "$bundle" 2>&1 | grep designated
if codesign -d --entitlements - --xml "$bundle/Contents/XPCServices/VolantInputHost.xpc" 2>/dev/null | grep -q app-sandbox; then
    echo "the helper must not be sandboxed" >&2
    exit 1
fi
echo "built $bundle"
