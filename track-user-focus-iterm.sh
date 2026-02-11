#!/bin/bash
# Track whether user was focused on this iTerm session when submitting a prompt

SESSION_ID="${ITERM_SESSION_ID:-}"
if [[ -z "$SESSION_ID" ]]; then
  exit 0
fi

UUID="${SESSION_ID##*:}"
STATE_FILE="/tmp/claude-focus-$UUID"

# Check if user is currently focused on this session
IS_FOCUSED=$(osascript -e "
  tell application \"System Events\"
    set frontApp to name of first application process whose frontmost is true
    if frontApp is not \"iTerm2\" then return false
  end tell
  tell application \"iTerm\"
    try
      set currentSession to current session of current tab of current window
      if unique ID of currentSession is \"$UUID\" then
        return true
      end if
    end try
  end tell
  return false
" 2>/dev/null)

# Record focus state and timestamp
echo "${IS_FOCUSED:-false} $(date +%s)" > "$STATE_FILE"
