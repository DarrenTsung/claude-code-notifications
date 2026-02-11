#!/bin/bash
# Activates a specific iTerm session by its unique ID
# ITERM_SESSION_ID format is "w0t0p0:UUID", but iTerm AppleScript uses just UUID
SESSION_ID="$1"
# Extract just the UUID part (after the colon)
UUID="${SESSION_ID##*:}"

osascript <<EOF
tell application "iTerm"
    activate
    repeat with aWindow in windows
        tell aWindow
            repeat with aTab in tabs
                tell aTab
                    repeat with aSession in sessions
                        if unique ID of aSession is "$UUID" then
                            select
                            tell aWindow to select
                            return
                        end if
                    end repeat
                end tell
            end repeat
        end tell
    end repeat
end tell
EOF
