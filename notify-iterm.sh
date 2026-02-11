#!/bin/bash
# Claude Code notification hook that differentiates between notification types
# (iTerm version — uses iTerm's AppleScript dictionary for per-session detection)

# Read JSON from stdin
INPUT=$(cat)

# Debug: log raw payload
echo "$(date -Iseconds) $INPUT" >> /tmp/claude-notify-debug.log

# Parse fields using jq
NOTIFICATION_TYPE=$(echo "$INPUT" | jq -r '.notification_type // "unknown"')
MESSAGE=$(echo "$INPUT" | jq -r '.message // ""')

# Get iTerm session ID from environment for click-to-activate
SESSION_ID="${ITERM_SESSION_ID:-}"
ACTIVATE_SCRIPT="$HOME/.claude/hooks/activate-iterm-session.sh"

# Get iTerm session name for notification context
SESSION_NAME=""
if [[ -n "$SESSION_ID" ]]; then
  UUID="${SESSION_ID##*:}"
  SESSION_NAME=$(osascript -e "
    tell application \"iTerm\"
      repeat with aWindow in windows
        tell aWindow
          repeat with aTab in tabs
            tell aTab
              repeat with aSession in sessions
                if unique ID of aSession is \"$UUID\" then
                  return name of aSession
                end if
              end repeat
            end tell
          end repeat
        end tell
      end repeat
    end tell
    return \"\"
  " 2>/dev/null)
fi

# Build title with session name if available
if [[ -n "$SESSION_NAME" ]]; then
  TITLE="Claude: $SESSION_NAME"
else
  TITLE="Claude Code"
fi

# Skip notification if user is currently viewing this session
if [[ -n "$SESSION_ID" ]]; then
  UUID="${SESSION_ID##*:}"

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

  if [[ "$IS_FOCUSED" == "true" ]]; then
    exit 0
  fi
fi

case "$NOTIFICATION_TYPE" in
  "idle_prompt")
    # Claude is waiting for user input
    terminal-notifier \
      -title "$TITLE" \
      -subtitle "Needs Input" \
      -message "${MESSAGE:-Awaiting your input}" \
      -sound Blow \
      -execute "$ACTIVATE_SCRIPT $SESSION_ID"
    ;;
  "tool_complete"|"agent_complete")
    # Task completed
    terminal-notifier \
      -title "$TITLE" \
      -subtitle "Done" \
      -message "${MESSAGE:-Task completed}" \
      -sound Glass \
      -execute "$ACTIVATE_SCRIPT $SESSION_ID"
    ;;
  "permission_prompt")
    if [[ "$MESSAGE" == *"plan"* ]]; then
      SUBTITLE="Plan Ready"
    else
      SUBTITLE="Permission Needed"
    fi
    terminal-notifier \
      -title "$TITLE" \
      -subtitle "$SUBTITLE" \
      -message "${MESSAGE:-Approval required}" \
      -sound Basso \
      -execute "$ACTIVATE_SCRIPT $SESSION_ID"
    ;;
  *)
    # Default/unknown notification
    terminal-notifier \
      -title "$TITLE" \
      -message "${MESSAGE:-Notification}" \
      -sound Pop \
      -execute "$ACTIVATE_SCRIPT $SESSION_ID"
    ;;
esac
