#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tools/core-module.sh
raycast_render_dir=$(mktemp -d /tmp/volant-raycast-render.XXXXXX)
trap 'rm -rf "$raycast_render_dir"' EXIT
cp tools/raycast/render.swift "$raycast_render_dir/main.swift"
swiftc -O "${VOLANT_CORE_FLAGS[@]}" Volant/Import/*.swift Volant/Snippets/Snippets.swift Volant/Quicklinks/Quicklinks.swift Volant/Handoff/DefaultHandler.swift Volant/HotKeys/KeyCombo.swift "$raycast_render_dir/main.swift" -o "$raycast_render_dir/render"
"$raycast_render_dir/render"
"$raycast_render_dir/render" dark
"$raycast_render_dir/render" empty
"$raycast_render_dir/render" dark compact
