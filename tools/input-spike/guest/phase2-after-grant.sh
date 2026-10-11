# SPIKE ONLY. Questions 1, 3, 4 and 5 after "Input Spike" was granted Accessibility.
source "/Volumes/My Shared Files/artifacts/lib.sh"
open -a TextEdit "$W/target.txt"; sleep 2
echo "### Q1: status after the grant (fresh host and service processes)"
spike status
echo "### Q1: taps from the service after the grant"
spike tap 3
tcc
echo "### Q1: can the sandboxed host use the grant itself?"
spike host-ax

echo "##### Q4 TextEdit (plain-text NSTextView)"
open -a TextEdit "$W/target.txt"; sleep 2
for m in ax paste unicode; do clear_field; insert_case TextEdit $m; done
shot 20-textedit

echo "##### Q4 Terminal (zsh prompt; Control-U clears the line between runs)"
open -a Terminal; sleep 4
for m in ax paste unicode; do NOUNDO=1 insert_case Terminal $m; spike key 32 262144 >/dev/null; done

echo "##### Q4 Safari textarea on a file:// page (input-event counter mirrored on the page)"
cp "$A/page.html" "$A/pw.html" "$W/"
for m in ax paste unicode; do
  open -a Safari "file://$W/page.html"; sleep 4; spike key 15 $CMD >/dev/null; sleep 3
  STATIC=events= insert_case "Safari textarea" $m
done
shot 21-safari

echo "##### Q4 Safari password field (length mirrored on the page)"
for m in ax paste unicode; do
  open -a Safari "file://$W/pw.html"; sleep 4; spike key 15 $CMD >/dev/null; sleep 3
  spike service-status | grep IsSecure
  NOUNDO=1 STATIC=pwlen= insert_case "Safari password" $m "secret" " words"
done
osascript -e 'quit app "Safari"' >/dev/null 2>&1

if [ -f "$A/chrome.zip" ]; then
  echo "##### Q4 Google Chrome (host-installed bundle copied in; no download)"
  [ -d "/Applications/Google Chrome.app" ] || ditto -x -k "$A/chrome.zip" /Applications/
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/Google Chrome.app"
  chrome() { pkill -x "Google Chrome"; sleep 2; open -na "/Applications/Google Chrome.app" --args --no-first-run --no-default-browser-check --user-data-dir=$W/chrome "file://$W/$1"; sleep 8; }
  for m in ax paste unicode; do
    chrome page.html
    NOUNDO=1 insert_case "Chrome textarea, tree not requested" $m
    spike manual-ax; sleep 2
    readback
    undo; echo -n "after 1 undo: "; readback | tail -1
    undo; echo -n "after 2 undos: "; readback | tail -1
  done
  chrome page.html; spike manual-ax; sleep 2
  STATIC=events= insert_case "Chrome textarea, tree enabled first" ax
  for m in ax paste unicode; do
    chrome pw.html
    spike service-status | grep IsSecure
    NOUNDO=1 insert_case "Chrome password" $m "secret" " words"
    spike manual-ax >/dev/null; sleep 2; spike static pwlen= | tail -1
  done
  shot 22-chrome-password
  pkill -x "Google Chrome"
fi

if [ -f "$A/obsidian.zip" ]; then
  echo "##### Q4 Obsidian (Electron; host-installed bundle copied in; note file read back from disk)"
  [ -d /Applications/Obsidian.app ] || ditto -x -k "$A/obsidian.zip" /Applications/
  mkdir -p "$W/vault/.obsidian" "$HOME/Library/Application Support/obsidian"
  printf '' > "$W/vault/Spike.md"
  printf '{"vaults":{"a1b2c3d4e5f60718":{"path":"%s/vault","ts":1760000000000,"open":true}}}' "$W" \
    > "$HOME/Library/Application Support/obsidian/obsidian.json"
  open /Applications/Obsidian.app; sleep 12
  open "obsidian://open?vault=vault&file=Spike"; sleep 5
  for m in ax paste unicode; do clear_field; READBACK="cat $W/vault/Spike.md" insert_case Obsidian $m; done
  spike manual-ax; sleep 2; clear_field
  READBACK="cat $W/vault/Spike.md" insert_case "Obsidian, tree enabled first" ax
  shot 23-obsidian
  pkill -x Obsidian
fi

echo "##### Q5 bare Escape and Return through Carbon in the sandboxed host, TextEdit frontmost"
open -a TextEdit "$W/target.txt"; sleep 2; clear_field
spike insert paste 0 "line one" >/dev/null
spike hotkey
echo "frontmost: $(front)"

echo "##### Q3 update survival: Developer ID build 1 -> build 2, fresh bundle swap"
spike status | grep -E "build=|AXIsProcess"
echo "csreq digest: $(csreq_digest)"
install_build b2
spike status | grep -E "build=|AXIsProcess|Listen"
tcc; echo "csreq digest: $(csreq_digest)"
echo "##### Q3 contrast: ad-hoc build 1 over the Developer ID grant"
install_build a1
spike status | grep -E "build=|AXIsProcess"
tcc
