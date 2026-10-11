#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tools/core-module.sh
volume_check_dir=$(mktemp -d /tmp/volant-volume-check.XXXXXX)
trap 'rm -rf "$volume_check_dir"' EXIT
cp tools/volume/check.swift "$volume_check_dir/main.swift"
swiftc "${VOLANT_CORE_FLAGS[@]}" Volant/SystemControl/VolumeControl.swift Volant/SystemControl/DictationVolume.swift "$volume_check_dir/main.swift" -o "$volume_check_dir/check"
"$volume_check_dir/check"
