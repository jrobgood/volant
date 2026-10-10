#!/bin/bash
# Counts icon fetches and times per-redraw icon work with and without IconCache over /System/Applications.
set -euo pipefail
cd "$(dirname "$0")/.."
renders=${1:-20}
[[ "$renders" =~ ^[0-9]+$ ]] && ((renders >= 2 && renders <= 1000)) || { echo 'Usage: tools/profile-icons.sh [renders=20]' >&2; exit 2; }
build=$(mktemp -d /tmp/volant-icon-cache.XXXXXX)
trap 'rm -rf "$build"' EXIT
swiftc -O Volant/Search/IconCache.swift tools/icon-cache/main.swift -o "$build/measure"
"$build/measure" uncached "$renders"
"$build/measure" cached "$renders"
