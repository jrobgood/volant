# Guest-side helpers for tools/input-host-e2e/run-vm.py. Runs inside a disposable Tart clone over
# SSH (whose responsible process holds the image's UI-scripting grant), never on the owner's Mac.
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
A='/Volumes/My Shared Files/artifacts'
W=/tmp/inputhost-e2e
mkdir -p "$W" "$A/shots"
APP=/Applications/Volant.app
ID=com.mysticcoders.volant

# Launches the harness through LaunchServices without activating it, so it is its own
# responsible process and the app in front keeps focus. Waits for it to exit.
volant() {
  rm -f "$W/out.txt" "$W/err.txt"
  open -g -n -W --stdout "$W/out.txt" --stderr "$W/err.txt" "$APP" --args "$@"
  cat "$W/out.txt"
  helper_gone
}

# The same, without waiting; `volant_wait` collects the output.
volant_bg() {
  rm -f "$W/out.txt" "$W/err.txt"
  open -g -n --stdout "$W/out.txt" --stderr "$W/err.txt" "$APP" --args "$@"
}
volant_wait() {
  for _ in $(seq 1 60); do pgrep -f "$APP/Contents/MacOS/Volant" >/dev/null || break; sleep 0.5; done
  cat "$W/out.txt"
  helper_gone
}

# The helper exits about a second after its only client disconnects.
helper_gone() {
  sleep 2
  if pgrep -x VolantInputHost >/dev/null; then echo "helper: STILL RUNNING"; else echo "helper: not running"; fi
}

tcc() {
  echo "--- TCC rows for $ID:"
  sudo sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
    "select service,client,auth_value,auth_reason from access where client like 'com.mysticcoders.volant%'"
}

shot() { screencapture -x "$A/shots/$1.png" && echo "screenshot $1"; }
front() { lsappinfo info -only bundleid "$(lsappinfo front)" | tail -1 | sed 's/.*=//'; }
key() { osascript -e "tell application \"System Events\" to key code $1${2:+ using $2}"; }

# What TextEdit's document holds, read by UI scripting from SSH, not by the helper.
textedit_text() { osascript -e 'tell application "System Events" to tell process "TextEdit" to get value of text area 1 of scroll area 1 of window 1' 2>&1; }
window_title() { osascript -e "tell application \"System Events\" to tell process \"$1\" to get name of window 1" 2>&1; }

new_textedit() {
  osascript -e 'quit app "TextEdit" saving no' >/dev/null 2>&1; sleep 1
  printf '' > "$W/target-$1.txt"
  open -a TextEdit "$W/target-$1.txt"; sleep 3
}

# Shows the clipboard's text and its types, to check the previous contents came back marked.
clipboard() {
  echo "clipboard text: $(pbpaste)"
  echo "clipboard types: $(osascript -l JavaScript -e 'ObjC.import("AppKit"); var t = $.NSPasteboard.generalPasteboard.types; var a = []; for (var i = 0; i < t.count; i++) a.push(ObjC.unwrap(t.objectAtIndex(i))); a.join(", ")' 2>&1)"
}

# Answers the Accessibility prompt with its Deny button (the grant is given in System Settings
# afterwards), so the alert does not stay in front of the apps under test.
dismiss_prompt() {
  osascript -e 'tell application "System Events" to tell process "UserNotificationCenter" to click button "Deny" of window 1' 2>&1
  sleep 1
  pgrep -x UserNotificationCenter >/dev/null && killall UserNotificationCenter 2>/dev/null
  sleep 1
  echo "frontmost after dismissing: $(front)"
}
