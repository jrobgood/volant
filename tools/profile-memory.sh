#!/bin/bash
# Explicit opt-in; never run against the owner's process or storage.
set -euo pipefail
cd "$(dirname "$0")/.."
source tools/core-module.sh
profile_output=${1:?Usage: tools/profile-memory.sh OUTPUT_DIRECTORY}
mkdir -p "$profile_output"
profile_output=$(cd "$profile_output" && pwd)
profile_bundle="$profile_output/Volant Memory Profile.app/Contents"
mkdir -p "$profile_bundle/MacOS" "$profile_bundle/Resources"
cp Volant/Resources/emoji.json "$profile_bundle/Resources/"
cat > "$profile_bundle/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>VolantMemoryProfile</string><key>CFBundleIdentifier</key><string>com.mysticcoders.volant.memoryprofile</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/></dict></plist>
PLIST
profile_sources=()
while IFS= read -r source; do profile_sources+=("$source"); done < <(rg --files Volant Shared -g '*.swift' | rg -v '^Volant/App/')
swiftc -O -g -target "$(uname -m)-apple-macosx15.0" "${VOLANT_CORE_FLAGS[@]}" "${profile_sources[@]}" VolantAgentHost/ACPConnection.swift tools/memory/acp-poll.swift tools/memory/main.swift -o "$profile_bundle/MacOS/VolantMemoryProfile"
# Ad-hoc signed measurement fixture, not a notarized/sandboxed release app.
codesign --force --sign - "$profile_output/Volant Memory Profile.app"
{
    git rev-parse HEAD
    shasum -a 256 tools/memory/main.swift tools/memory/acp-poll.swift
    sw_vers
    uname -m
    swiftc --version
    sysctl hw.memsize hw.model
} > "$profile_output/environment.txt"
# VOLANT_MEMORY_SCENARIOS narrows a focused rerun, such as "notes notes-small".
read -r -a profile_scenarios <<< "${VOLANT_MEMORY_SCENARIOS:-idle emoji clipboard image-decode notes notes-small acp acp-poll-small acp-poll-200k acp-poll-1m}"
for repetition in 1 2 3; do
    for scenario in "${profile_scenarios[@]}"; do
        "$profile_bundle/MacOS/VolantMemoryProfile" "$scenario" > "$profile_output/$scenario-$repetition.csv"
    done
done

python3 tools/memory/summarize.py "$profile_output" > "$profile_output/summary.md"
