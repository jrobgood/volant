#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tools/core-module.sh
raycast_check_dir=$(mktemp -d /tmp/volant-raycast-check.XXXXXX)
trap 'rm -rf "$raycast_check_dir"' EXIT
"${VOLANT_TEST_PYTHON:-python3}" tools/raycast/fixture.py "$raycast_check_dir/fixture.rayconfig"
cp tools/raycast/check.swift "$raycast_check_dir/main.swift"
swiftc -O "${VOLANT_CORE_FLAGS[@]}" Volant/Import/RaycastArchive.swift Volant/Import/RaycastImportPlan.swift Volant/Snippets/Snippets.swift Volant/Quicklinks/Quicklinks.swift Volant/Handoff/DefaultHandler.swift Volant/HotKeys/KeyCombo.swift "$raycast_check_dir/main.swift" -o "$raycast_check_dir/check"
"$raycast_check_dir/check" "$raycast_check_dir"
