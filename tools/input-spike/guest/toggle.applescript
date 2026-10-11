on run argv
	set target to item 1 of argv
	set out to ""
	tell application "System Events"
		tell process "System Settings"
			set els to entire contents of window 1
			repeat with e in els
				try
					if role of e is "AXCheckBox" then
						set n to ""
						try
							set n to name of e
						end try
						set d to ""
						try
							set d to description of e
						end try
						set out to out & "checkbox name=" & n & " desc=" & d & " value=" & ((value of e) as text) & linefeed
						if n is target or d is target then
							click e
							set out to out & "clicked " & target & linefeed
						end if
					end if
				end try
			end repeat
		end tell
	end tell
	return out
end run
