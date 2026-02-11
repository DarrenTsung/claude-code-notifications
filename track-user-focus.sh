#!/bin/bash
# Track whether user was focused on Warp when submitting a prompt.
# Warp has no AppleScript dictionary or per-session env vars, so we can only
# check app-level focus. The process name in System Events is "stable".

STATE_FILE="/tmp/claude-focus-$$"

IS_FOCUSED=$(osascript -e "
  tell application \"System Events\"
    set frontApp to name of first application process whose frontmost is true
    if frontApp is \"stable\" then return true
  end tell
  return false
" 2>/dev/null)

# Record focus state and timestamp
echo "${IS_FOCUSED:-false} $(date +%s)" > "$STATE_FILE"
