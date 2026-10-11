# SPIKE ONLY. Ad-hoc contrast for question 3. "request" resets and prompts for the installed
# ad-hoc build 1; "check" runs after grant.sh, then swaps in ad-hoc build 2.
source "/Volumes/My Shared Files/artifacts/lib.sh"
if [ "$1" = request ]; then
  tccutil reset Accessibility $ID
  spike request-ax; sleep 2; tcc
else
  echo "### ad-hoc build 1 after its own grant"
  spike status | grep -E "build=|AXIsProcess"
  install_build a2
  spike status | grep -E "build=|AXIsProcess"
  tcc
fi
