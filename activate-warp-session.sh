#!/bin/bash
# Brings Warp to the foreground.
# Warp has no AppleScript dictionary, so we cannot target a specific
# tab or pane — we can only activate the application.

osascript -e 'tell application "Warp" to activate'
