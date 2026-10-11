# End-to-end checks of the shipped input helper inside a disposable Tart clone. Each step prints
# what the harness reported, then what actually landed in the target app, read independently by
# UI scripting from SSH (never through the helper). Run by tools/input-host-e2e/run-vm.py.
source "/Volumes/My Shared Files/artifacts/lib.sh"
sw_vers
step() { echo; echo "##### $*"; }

step "install"
rm -rf "$APP" "$W/unpack"; mkdir -p "$W/unpack"
ditto -x -k "$A/volant.zip" "$W/unpack" && mv "$W/unpack/Volant.app" "$APP"
codesign -dvv "$APP" 2>&1 | grep -E "^Identifier|^TeamIdentifier|^Authority=Developer"
# `after-grant` reruns the checks against a rebuilt bundle in a kept clone, keeping the grant.
if [ "${1:-}" != after-grant ]; then
tccutil reset Accessibility "$ID" >/dev/null 2>&1
tcc
pgrep -x VolantInputHost >/dev/null && echo "helper running before first use" || echo "helper not running before first use"

step "before the grant: status without prompt, then with prompt"
new_textedit 0
volant status
sleep 4; tcc
volant status-prompt
sleep 3; shot prompt; tcc
dismiss_prompt
step "before the grant: typing falls back to copying"
new_textedit 1
printf 'SENTINEL-1' | pbcopy
volant type finished 0 "Should not be typed."
echo "TextEdit holds: [$(textedit_text)]"
clipboard

step "grant Accessibility to Volant in System Settings"
bash "$A/grant.sh"
fi
volant status

step "TextEdit, live: three phrases 0.4 s apart"
new_textedit 2
printf 'SENTINEL-2' | pbcopy
volant type live 0.4 "Hello there." " This is live dictation." " Café 👍 done."
echo "TextEdit holds: [$(textedit_text)]"
echo "frontmost: $(front)"
clipboard
shot textedit-live
key 6 "command down"; sleep 1
echo "after one Command-Z: [$(textedit_text)]"

step "TextEdit, when finished"
new_textedit 3
volant type finished 0 "Typed once at the end."
echo "TextEdit holds: [$(textedit_text)]"

step "Return finishes and is consumed while registered, then reaches the app again"
new_textedit 4
volant_bg type-until-return "Return test."
sleep 3
key 36; sleep 0.5
volant_wait
echo "TextEdit holds: [$(textedit_text)]"
key 36; sleep 0.5
key 0; sleep 0.5
echo "after Return and 'a' typed by UI scripting: [$(textedit_text)]"

step "stale token"
volant stale

step "app changed between phrases"
new_textedit 5
printf 'SENTINEL-6' | pbcopy
volant_bg type live 3 "First." " Second."
sleep 1.5
open -a Finder; sleep 0.5
echo "frontmost now: $(front)"
volant_wait
echo "TextEdit (in the background) holds: [$(textedit_text)]"
clipboard

step "one helper process, two dictations: TextEdit, then Terminal launched after the helper started"
osascript -e 'quit app "Terminal"' >/dev/null 2>&1
new_textedit 6
volant_bg two-sessions 6 "One." "echo two"
sleep 2
open -a Terminal; sleep 1
echo "frontmost now: $(front)"
volant_wait
echo "TextEdit (in the background) holds: [$(textedit_text)]"

step "app changed between phrases, both in a paste-only app (Terminal, then Finder)"
open -a Terminal; sleep 4
printf 'SENTINEL-7' | pbcopy
volant_bg type live 3 "echo one" " two"
sleep 1.5
open -a Finder; sleep 0.5
echo "frontmost now: $(front)"
volant_wait
clipboard
osascript -e 'quit app "Terminal"' >/dev/null 2>&1

if [ -f "$A/chrome.zip" ]; then
  step "Google Chrome (host-installed bundle copied in; no download)"
  [ -d "/Applications/Google Chrome.app" ] || ditto -x -k "$A/chrome.zip" /Applications/
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/Google Chrome.app"
  cp "$A/page.html" "$A/pw.html" "$W/"
  chrome() { pkill -x "Google Chrome"; sleep 2; open -na "/Applications/Google Chrome.app" --args --no-first-run --no-default-browser-check --user-data-dir=$W/chrome "file://$W/$1"; sleep 8; }
  step "Chrome textarea, live (no focused element exposed, so paste)"
  chrome page.html
  printf 'SENTINEL-3' | pbcopy
  volant type live 0.4 "Hello Chrome." " Second phrase." " Café 👍."
  sleep 1
  echo "Chrome title: [$(window_title "Google Chrome")]"
  echo "frontmost: $(front)"
  clipboard
  shot chrome-textarea
  step "Chrome textarea with an image on the clipboard"
  chrome page.html
  osascript -e "set the clipboard to (read (POSIX file \"$A/shots/chrome-textarea.png\") as «class PNGf»)"
  clipboard
  volant type finished 0 "Image kept."
  sleep 1
  echo "Chrome title: [$(window_title "Google Chrome")]"
  clipboard
  step "Chrome password field"
  chrome pw.html
  volant status
  printf 'SENTINEL-4' | pbcopy
  volant type live 0.4 "secret" " words"
  sleep 1
  echo "Chrome title: [$(window_title "Google Chrome")]"
  clipboard
  shot chrome-password
  pkill -x "Google Chrome"
fi

step "Safari password field"
cp "$A/pw.html" "$W/"
open -a Safari "file://$W/pw.html"; sleep 5
key 15 "command down"; sleep 4
volant status
printf 'SENTINEL-5' | pbcopy
volant type live 0.4 "secret" " words"
sleep 1
echo "Safari title: [$(window_title Safari)]"
clipboard
shot safari-password
osascript -e 'quit app "Safari"' >/dev/null 2>&1

step "after all runs"
pgrep -x VolantInputHost >/dev/null && echo "helper: STILL RUNNING" || echo "helper: not running"
tcc
step "helper log (attribute names, error codes and pids only)"
log show --info --last 30m --style compact --predicate 'subsystem == "com.mysticcoders.volant" AND category == "InputHost"' 2>&1 | tail -60
step "crash reports"
ls -t ~/Library/Logs/DiagnosticReports /Library/Logs/DiagnosticReports 2>/dev/null | head -20
for report in $(ls -t ~/Library/Logs/DiagnosticReports/*Volant* 2>/dev/null | head -2); do echo "== $report"; head -80 "$report"; done
