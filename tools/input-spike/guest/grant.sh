# SPIKE ONLY. Grants Accessibility to "Input Spike" through System Settings' own switch and
# password sheet, driven by AppleScript UI scripting. Runs over SSH because the image grants
# sshd-keygen-wrapper Accessibility; synthesized keystrokes into the password sheet are ignored,
# so the password is set through the sheet's AX value instead. Disposable guest only.
source "/Volumes/My Shared Files/artifacts/lib.sh"
has_sheet() { osascript -e 'tell application "System Events" to tell process "System Settings" to return (count of sheets of window 1)' 2>/dev/null; }
for attempt in 1 2 3; do
  pkill -x "System Settings"; sleep 2
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"; sleep 8
  osascript "$A/toggle.applescript" "Input Spike"
  sleep 3
  [ "$(has_sheet)" = 1 ] && break
  echo "no password sheet after attempt $attempt"
done
shot "${1:-10}-password-sheet"
osascript <<'EOF'
tell application "System Events" to tell process "System Settings"
  set els to entire contents of sheet 1 of window 1
  repeat with e in els
    try
      if subrole of e is "AXSecureTextField" then
        set focused of e to true
        set value of e to "admin"
        log "password set through AX"
      end if
    end try
  end repeat
  delay 0.5
  repeat with e in els
    try
      if role of e is "AXButton" and name of e is "Modify Settings" then
        click e
        log "clicked Modify Settings"
      end if
    end try
  end repeat
end tell
EOF
sleep 3
shot "${1:-10}-after-grant"
tcc
pkill -x "System Settings"
