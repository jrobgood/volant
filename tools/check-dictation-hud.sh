#!/bin/bash
# Renders the floating dictation indicator from the production views, checks that it never takes
# key focus or activates the process, and writes light and dark captures for each state.
set -euo pipefail
cd "$(dirname "$0")/.."
source tools/core-module.sh
hud_check_dir=$(mktemp -d /tmp/volant-dictation-hud-check.XXXXXX)
trap 'rm -rf "$hud_check_dir"' EXIT
cp tools/launcher/dictation-hud.swift "$hud_check_dir/main.swift"
python3 tools/run-bounded-check.py 300 "Compile dictation indicator fixture" swiftc "${VOLANT_CORE_FLAGS[@]}" \
    Volant/Appearance/ThemeStore.swift Volant/Dictation/DictationIndicator.swift Volant/Dictation/DictationIndicatorPanel.swift \
    "$hud_check_dir/main.swift" -o "$hud_check_dir/check"
python3 tools/run-bounded-check.py 60 "Light dictation indicator" "$hud_check_dir/check"
python3 tools/run-bounded-check.py 60 "Dark dictation indicator" "$hud_check_dir/check" dark
