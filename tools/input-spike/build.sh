#!/bin/bash
# SPIKE ONLY. Not shipped, not part of any app target. See docs/input-host-spike.md.
#
# Builds "Input Spike.app": a sandboxed container (com.mysticcoders.volant.inputspike) with an
# embedded unsandboxed XPC service, VolantInputHost (com.mysticcoders.volant.inputspike.InputHost),
# shaped like VolantAgentHost and the design's proposed VolantInputHost. Building signs but never
# runs it: every TCC and insertion probe runs in a disposable Tart guest (tools/input-spike/run-vm.py).
#
# Usage: build.sh <out-dir> [build-number] [identity]
#   identity defaults to the Developer ID used for releases; "-" builds an ad-hoc pair.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=${1:?usage: build.sh <out-dir> [build-number] [identity]}
build=${2:-1}
identity=${3:-${VOLANT_SIGN_IDENTITY:-'Developer ID Application: Mystic Coders, LLC (REMBT6JY4N)'}}
mkdir -p "$out"

bundle="$out/Input Spike.app"
rm -rf "$bundle"
app="$bundle/Contents"
service="$app/XPCServices/VolantInputHost.xpc/Contents"
mkdir -p "$app/MacOS" "$service/MacOS"

cat > "$service/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleExecutable</key><string>VolantInputHost</string>
<key>CFBundleIdentifier</key><string>com.mysticcoders.volant.inputspike.InputHost</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleName</key><string>VolantInputHost</string>
<key>CFBundlePackageType</key><string>XPC!</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
<key>CFBundleVersion</key><string>$build</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>XPCService</key><dict>
  <key>ServiceType</key><string>Application</string>
  <key>JoinExistingSession</key><true/>
  <key>RunLoopType</key><string>NSRunLoop</string>
</dict>
</dict></plist>
PLIST

cat > "$app/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleExecutable</key><string>InputSpike</string>
<key>CFBundleIdentifier</key><string>com.mysticcoders.volant.inputspike</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleName</key><string>Input Spike</string>
<key>CFBundleDisplayName</key><string>Input Spike</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
<key>CFBundleVersion</key><string>$build</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST

# Top-level code must live in main.swift when more than one file is compiled together, and the
# deployment target must match Volant's, or the guest cannot load the host-built Swift runtime.
mkdir -p "$out/src/service" "$out/src/client"
cp tools/input-spike/service.swift "$out/src/service/main.swift"
cp tools/input-spike/client.swift "$out/src/client/main.swift"
target="$(uname -m)-apple-macosx15.0"
swiftc -O -target "$target" tools/input-spike/protocol.swift "$out/src/service/main.swift" -o "$service/MacOS/VolantInputHost"
swiftc -O -target "$target" tools/input-spike/protocol.swift "$out/src/client/main.swift" -o "$app/MacOS/InputSpike"

# The service carries no entitlements, which is how VolantAgentHost ships: no app-sandbox key
# means it runs outside the sandbox. The container carries Volant's sandbox entitlement.
cat > "$out/service.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict/></plist>
PLIST
cat > "$out/client.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>com.apple.security.app-sandbox</key><true/>
</dict></plist>
PLIST

timestamp=--timestamp
[ "$identity" = "-" ] && timestamp=--timestamp=none
codesign --force --sign "$identity" --options runtime $timestamp \
    --entitlements "$out/service.entitlements" "$app/XPCServices/VolantInputHost.xpc"
codesign --force --sign "$identity" --options runtime $timestamp \
    --entitlements "$out/client.entitlements" "$bundle"
codesign --verify --deep --strict "$bundle"
echo "built $bundle (build $build, identity $identity)"
codesign -d -r- "$bundle" 2>&1 | grep designated
codesign -d -r- "$app/XPCServices/VolantInputHost.xpc" 2>&1 | grep designated
