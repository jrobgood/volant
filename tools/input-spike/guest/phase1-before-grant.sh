# SPIKE ONLY. Questions 1 and 2 before any grant: which identity TCC charges, whether a
# prompt-free status check creates a Privacy entry, and what each request shows.
source "/Volumes/My Shared Files/artifacts/lib.sh"
sw_vers; xcodebuild -version 2>/dev/null | head -1; csrutil status
reset_all() { tccutil reset Accessibility $ID >/dev/null 2>&1; tccutil reset ListenEvent $ID >/dev/null 2>&1; }
echo "### install build 1 (Developer ID)"
install_build b1
spctl -a -vv "$APP" 2>&1 | head -2
reset_all; tcc
printf '' > "$W/target.txt"
open -a TextEdit "$W/target.txt"; sleep 4
echo "### Q2a: service-only status (AXIsProcessTrustedWithOptions prompt:false, listen/post preflight)"
spike service-status
sleep 5; tcc
reset_all
echo "### Q2b: sandboxed host-only status (same calls, from the container itself)"
spike host-status
sleep 5; tcc
reset_all
echo "### Q2c: service-only status, then Privacy & Security > Accessibility"
spike service-status >/dev/null
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"; sleep 5
echo "frontmost: $(front)"
shot 01-accessibility-list-after-prompt-false
pkill -x "System Settings"; sleep 1
open -a TextEdit "$W/target.txt"; sleep 2
echo "### Q1: Input Monitoring request from the service, then from the host"
spike request-listen
sleep 2; shot 02-after-service-request-listen
spike host-request-listen
sleep 2; tcc
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"; sleep 4
shot 03-input-monitoring-list
pkill -x "System Settings"; sleep 1
open -a TextEdit "$W/target.txt"; sleep 2
echo "### Q1: taps from the service before any grant"
spike tap 3
echo "### Q1: Accessibility request (prompt:true) from the service"
spike request-ax
sleep 2; shot 04-accessibility-prompt
echo "frontmost: $(front)"
tcc
echo "### tccd attribution for the service's requests"
log show --last 5m --predicate 'process == "tccd"' 2>/dev/null > "$W/tccd.log"
echo "requests made by the service process: $(grep -c "AUTHREQ_ATTRIBUTION.*requesting={TCCDProcess: identifier=$ID.InputHost" "$W/tccd.log")"
echo "subjects charged: $(grep -o "AUTHREQ_SUBJECT: msgID=[0-9.]*, subject=[^,]*" "$W/tccd.log" | sed 's/.*subject=//' | sort | uniq -c | tr '\n' ';')"
