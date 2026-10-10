#!/usr/bin/env python3
"""Shared local/CI change classification. Include dirty files locally, never launch UI."""
import argparse
import fnmatch
import json
import subprocess
from pathlib import Path

UI_PATTERNS = (
    "Volant/**/*View.swift", "Volant/**/*Panel.swift", "Volant/**/*WindowController.swift",
    "Volant/Search/AppIndex.swift", "Volant/Search/IconCache.swift", "Volant/Files/FileSearch.swift", "Volant/Notes/NotesStore.swift", "Volant/Clipboard/*", "Volant/Extensions/*", "Core/Sources/VolantCore/Extensions/*", "VolantExtensionHost/*", "extensions/*", "Volant/Panel/*", "Core/Sources/VolantCore/Calculator/TimeCalculator.swift", "Volant/Usage/UsageStore.swift", "Volant/Shortcuts/*", "Core/Sources/VolantCore/Shortcuts/*", "Volant/Emoji/*", "Volant/Translation/*", "Volant/Dictionary/*", "Volant/Settings/Shortcut*.swift", "Volant/Settings/GlobalShortcutRow.swift",
    "Core/Sources/VolantCore/Settings/*", "Core/Sources/VolantCore/AI/*", "Volant/Settings/AppBindingEditor.swift", "Volant/Settings/AppBindingRow.swift", "Volant/HotKeys/KeyCombo.swift", "Volant/Settings/StatusMenu.swift", "Volant/Settings/SettingsStyle.swift", "Volant/Settings/ICloudSettingsSync.swift", "Volant/Settings/CryptoKeySection.swift",
    "Volant/Notes/LiveMarkdown*.swift", "Volant/Agents/*Model.swift", "Volant/Agents/HerdrFooterStatus.swift", "Volant/Agents/HerdrQueryHeader.swift", "Volant/Agents/ChatContextPicker.swift",
    "Volant/App/main.swift", "Volant/App/AppDelegate.swift", "Volant/Resources/*", "Volant/Appearance/*",
    "Volant/Settings/AIModelDiscovery.swift", "Volant/Settings/ACPAgentDetection.swift", "Volant/Settings/AICredentials.swift", "Core/Sources/VolantCore/Clipboard/*", "Core/Sources/VolantCore/Emoji/*", "Core/Sources/VolantCore/Launcher/*", "Core/Sources/VolantCore/Agents/*", "Core/Sources/VolantCore/Herdr/*", "Shared/HerdrQuestion.swift", "Shared/HerdrClaudeQuestion.swift", "Shared/HerdrResponseController.swift", "Volant/SystemControl/SystemSettingsDestination.swift",
    "tools/interaction-speed/*.swift", "tools/profile-interaction.sh", "tools/launcher/*", "tools/settings/*", "tools/themes/*", "tools/marketing/*", "tools/raycast/render.swift",
    "tools/check-launcher.sh", "tools/check-launcher-actions.sh", "tools/run-bounded-check.py", "tools/test-ui-vm.py", "tools/preview-settings.sh", "tools/render-*.sh",
    "VolantTests/LiveMarkdownTests.swift", "VolantTests/NotesStoreTests.swift",
)
NATIVE_PATTERNS = ("Volant/*", "VolantTests/*", "VolantAgentHost/*", "VolantExtensionHost/*", "VolantAIHost/*",
                   "Shared/*", "Core/*", "extensions/*", "Scripts/*", "tools/*", "project.yml", ".swiftlint.yml", ".github/workflows/*")


def classify(paths):
    return {"native": any(fnmatch.fnmatch(p, pattern) for p in paths for pattern in NATIVE_PATTERNS),
            "ui": any(fnmatch.fnmatch(p, pattern) for p in paths for pattern in UI_PATTERNS)}


def git(*args):
    return subprocess.check_output(["git", *args]).decode().split("\0")


def changed(base, head, dirty=False):
    paths = git("diff", "--name-only", "--no-renames", "-z", base + "..." + head)
    if dirty:
        paths += git("diff", "--name-only", "--no-renames", "-z", "HEAD")
        paths += git("ls-files", "--others", "--exclude-standard", "-z")
    return sorted(set(filter(None, paths)))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="origin/main")
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--include-working-tree", action="store_true")
    parser.add_argument("--github-output")
    args = parser.parse_args()
    paths = changed(args.base, args.head, args.include_working_tree)
    scope = classify(paths)
    print(json.dumps({**scope, "files": paths}, indent=2))
    if args.github_output:
        with Path(args.github_output).open("a") as output:
            for key, value in scope.items():
                output.write(f"{key}={str(value).lower()}\n")
