# SPIKE ONLY. Guest-side helpers for tools/input-spike/run-vm.py. Runs inside a disposable
# Tart clone, never on the owner's Mac. See docs/input-host-spike.md.
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
A='/Volumes/My Shared Files/artifacts'
W=/tmp/inputspike
mkdir -p "$W" "$A/shots"
APP="/Applications/Input Spike.app"
CMD=1048576
ID=com.mysticcoders.volant.inputspike

# Launches the sandboxed host through LaunchServices without activating it, so the host is its
# own responsible process (not the guest agent, which holds its own Accessibility grant).
spike() {
  rm -f "$W/out.txt" "$W/err.txt"
  open -g -n -W --stdout "$W/out.txt" --stderr "$W/err.txt" "$APP" --args "$@"
  cat "$W/out.txt"
}

tcc() {
  echo "--- system TCC.db rows for $ID:"
  sudo sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
    "select service,client,client_type,auth_value,auth_reason from access where client like '%inputspike%'"
}

csreq_digest() {
  sudo sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
    "select hex(csreq) from access where client='$ID' and service='kTCCServiceAccessibility'" | shasum | cut -c1-12
}

shot() { screencapture -x "$A/shots/$1.png" && echo "screenshot $1"; }

front() { lsappinfo info -only bundleid "$(lsappinfo front)" | tail -1 | sed 's/.*=//'; }

# Replaces the installed bundle as Sparkle does: the old bundle goes, a fresh one moves in.
install_build() {
  pkill -f "Input Spike.app" 2>/dev/null
  rm -rf "$W/unpack" && mkdir -p "$W/unpack"
  ditto -x -k "$A/$1.zip" "$W/unpack"
  rm -rf "$APP"
  mv "$W/unpack/Input Spike.app" "$APP"
  echo "installed $1: build $(defaults read "$APP/Contents/Info" CFBundleVersion)"
  codesign -dvvv "$APP" 2>&1 | grep -E "^CDHash=|^Signature=|^TeamIdentifier="
}

clear_field() { spike key 0 $CMD >/dev/null; spike key 51 0 >/dev/null; sleep 0.5; }
undo() { spike key 6 $CMD >/dev/null; sleep 0.7; }

# One insertion run: clipboard sentinel, phrases 0.4 s apart (three dictation phrases unless
# others follow the method), read-back and two undos. Read-back uses the service's diagnostic
# AX read, or $READBACK when it is set.
insert_case() {
  local label=$1 method=$2
  shift 2
  [ $# -eq 0 ] && set -- "Hello there." " This is live dictation." " Café 👍 done."
  echo "----- $label / $method"
  spike focused
  printf 'ORIGINAL-CLIP' | pbcopy
  spike insert "$method" 0.4 "$@" | grep -E "phrase|before|after"
  echo "frontmost after: $(front)"
  echo "clipboard after: $(pbpaste)"
  readback
  if [ "${NOUNDO:-}" != 1 ]; then
    undo; echo -n "after 1 undo: "; readback | tail -1
    undo; echo -n "after 2 undos: "; readback | tail -1
  fi
}

readback() {
  if [ -n "${READBACK:-}" ]; then sleep 3; echo "value=$(eval "$READBACK" | tr '\n' '|')"; else spike read | tail -1; fi
  [ -n "${STATIC:-}" ] && spike static "$STATIC" | tail -1
  return 0
}
