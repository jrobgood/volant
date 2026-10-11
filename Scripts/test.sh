#!/bin/bash
# Select UI verification from the diff; --ui always/never/only is an explicit override.
set -euo pipefail
cd "$(dirname "$0")/.."
ui_mode=auto
base=origin/main
ci=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ui) ui_mode="$2"; shift 2 ;;
        --base) base="$2"; shift 2 ;;
        --ci) ci=true; shift ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done
case "$ui_mode" in auto|always|never|only) ;; *) echo 'Invalid --ui mode' >&2; exit 2 ;; esac
run_ui=false
if [[ "$ui_mode" == auto ]]; then
    scope_json=$(python3 tools/test-scope.py --base "$base" --include-working-tree)
    run_ui=$(printf '%s' "$scope_json" | python3 -c 'import json,sys; print(str(json.load(sys.stdin)["ui"]).lower())')
elif [[ "$ui_mode" != never ]]; then
    run_ui=true
fi
printf 'UI verification: %s (mode: %s)\n' "$run_ui" "$ui_mode"
python3 tools/test-scope-tests.py
python3 tools/check-input-confinement.py --self-test
python3 tools/check-input-confinement.py
python3 tools/interaction-speed/check.py
python3 tools/ui-vm-dispatch-tests.py
xcodegen generate --quiet
build_options=(-project Volant.xcodeproj -scheme Volant -derivedDataPath build -destination 'platform=macOS')
if [[ "$ci" == true ]]; then
    build_options+=(CODE_SIGNING_ALLOWED=NO ENABLE_APP_SANDBOX=NO)
fi
if [[ "$ui_mode" != only ]]; then
    python3 tools/check-bundle-migration.py
    swiftlint lint --strict --quiet --config .swiftlint.yml
    ./tools/check-raycast.sh
    ./tools/check-volume.sh
    ./tools/check-acp.sh
    ./tools/check-ai-http.sh
    ./tools/check-extensions.sh
    xcodebuild "${build_options[@]}" test -skip-testing:VolantTests/NotesRenderTests \
        -skip-testing:VolantTests/LiveMarkdownTests/testLanguageChangePreservesContentSelectionAndUndo \
        -skip-testing:VolantTests/LiveMarkdownTests/testTypingFenceAndChangingModesDoNotRewriteSource
fi
if [[ "$run_ui" == true ]]; then
    if [[ "$ci" != true && "${VOLANT_HOST_UI_TESTS:-0}" != 1 ]]; then
        python3 tools/test-ui-vm.py
        exit 0
    fi
    ./tools/check-launcher.sh
    ./tools/check-launcher-actions.sh
    ./tools/check-dictation-hud.sh
    xcodebuild "${build_options[@]}" test -only-testing:VolantTests/NotesRenderTests \
        -only-testing:VolantTests/LiveMarkdownTests/testLanguageChangePreservesContentSelectionAndUndo \
        -only-testing:VolantTests/LiveMarkdownTests/testTypingFenceAndChangingModesDoNotRewriteSource
else
    echo 'Skipped native UI/keyboard/render fixtures: no UI changes, or explicitly disabled.'
fi
