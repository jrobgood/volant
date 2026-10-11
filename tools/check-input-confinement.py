#!/usr/bin/env python3
"""Fail if Accessibility or event-posting APIs appear outside VolantInputHost/.

Phase 0 showed that once the owner grants Accessibility to Volant, the sandboxed main app also reads
as trusted and can create a listen-only event tap. The sandbox does not stop that, so this check
does: only the input helper may call these APIs. The Phase 0 spike sources are exempt because they
are not part of any target. Run with --self-test to check the matcher itself.
"""
import re
import os
import subprocess
import sys
import unittest

ALLOWED_PREFIXES = ("VolantInputHost/", "tools/input-spike/")
SOURCE_SUFFIXES = (".swift", ".m", ".mm", ".c", ".h")
FORBIDDEN = re.compile(
    r"AXUIElement\w*|AXIsProcessTrusted\w*|kAXTrustedCheckOption\w*|"
    r"CGEventPost\w*|CGEventCreateKeyboardEvent|CGEventTapCreate\w*|CGEventKeyboardSetUnicodeString|"
    r"\btapCreate\s*\(|CGEvent\s*\(\s*keyboardEventSource|\.post\s*\(\s*tap\s*:|\.postToPid\s*\(|"
    r"keyboardSetUnicodeString"
)


def violations(files):
    """Yields (path, line number, match) for each forbidden use in `files`, a mapping of path to text."""
    for path, text in sorted(files.items()):
        if path.startswith(ALLOWED_PREFIXES) or not path.endswith(SOURCE_SUFFIXES):
            continue
        for number, line in enumerate(text.splitlines(), 1):
            match = FORBIDDEN.search(line)
            if match:
                yield path, number, match.group(0)


SKIPPED_DIRECTORIES = {".git", "build", "build-release", "dist", "node_modules", ".build", ".wrangler"}


def source_names():
    """Repository file names: git's tracked and untracked non-ignored files, or, in a source copy
    without git metadata such as the Tart VM's tarball, every file outside build output."""
    try:
        listed = subprocess.check_output(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
                                         stderr=subprocess.DEVNULL)
        return listed.decode().split("\0")
    except (subprocess.CalledProcessError, FileNotFoundError):
        names = []
        for root, directories, files in os.walk("."):
            directories[:] = [d for d in directories if d not in SKIPPED_DIRECTORIES and not d.startswith("dist-release")]
            names.extend(os.path.relpath(os.path.join(root, name)) for name in files)
        return names


def tracked_sources():
    """Tracked and untracked, non-ignored source files with their contents."""
    names = source_names()
    files = {}
    for name in filter(None, names):
        if name.endswith(SOURCE_SUFFIXES):
            try:
                with open(name, encoding="utf-8", errors="replace") as handle:
                    files[name] = handle.read()
            except FileNotFoundError:
                continue
    return files


class ConfinementTests(unittest.TestCase):
    def test_flags_each_api_outside_the_helper(self):
        samples = [
            "let element = AXUIElementCreateSystemWide()",
            "AXIsProcessTrustedWithOptions(options)",
            "let key = kAXTrustedCheckOptionPrompt",
            "CGEventPost(kCGHIDEventTap, event);",
            "CGEventRef e = CGEventCreateKeyboardEvent(NULL, 9, true);",
            "CFMachPortRef tap = CGEventTapCreate(kCGSessionEventTap, 0, 0, mask, cb, NULL);",
            "let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: m, callback: c, userInfo: nil)",
            "let event = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)",
            "event?.post(tap: .cghidEventTap)",
            "event.postToPid(pid)",
            "event.keyboardSetUnicodeString(stringLength: 1, unicodeString: p)",
        ]
        for sample in samples:
            for path in ["Volant/App/AppDelegate.swift", "Shared/Thing.swift", "VolantAgentHost/main.swift", "Core/Sources/VolantCore/X.swift", "tools/launcher/check.swift"]:
                self.assertEqual(len(list(violations({path: sample}))), 1, (path, sample))

    def test_helper_and_spike_are_exempt(self):
        text = "AXUIElementCreateSystemWide(); event.post(tap: .cghidEventTap)"
        self.assertEqual(list(violations({"VolantInputHost/SystemInput.swift": text, "tools/input-spike/service.swift": text})), [])

    def test_ignores_docs_scripts_and_harmless_code(self):
        self.assertEqual(list(violations({"docs/design.md": "AXUIElementCreateSystemWide()", "tools/check.py": "CGEventPost"})), [])
        self.assertEqual(list(violations({"Volant/X.swift": "let event = NSEvent.keyEvent(with: .keyDown)\nNotificationCenter.default.post(name: n)"})), [])

    def test_repository_is_clean(self):
        self.assertEqual(list(violations(tracked_sources())), [])


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        sys.argv.remove("--self-test")
        unittest.main()
    found = list(violations(tracked_sources()))
    for path, number, match in found:
        print(f"{path}:{number}: {match} is allowed only in VolantInputHost/", file=sys.stderr)
    if found:
        sys.exit(1)
    print("Input confinement: Accessibility and event APIs appear only in VolantInputHost/")
