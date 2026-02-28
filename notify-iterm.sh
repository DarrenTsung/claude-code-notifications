#!/bin/bash
# Claude Code notification hook that differentiates between notification types
# (iTerm version — uses iTerm's AppleScript dictionary for per-session detection)

# Read JSON from stdin
INPUT=$(cat)

# Debug: log raw payload
echo "$(date -Iseconds) $INPUT" >> /tmp/claude-notify-debug.log

# Parse fields using jq
HOOK_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // ""')
NOTIFICATION_TYPE=$(echo "$INPUT" | jq -r '.notification_type // "unknown"')
MESSAGE=$(echo "$INPUT" | jq -r '.message // ""')

# Skip PermissionRequest events — Claude Code always follows them with a
# Notification event that has proper notification_type and message.
if [[ "$HOOK_EVENT" == "PermissionRequest" ]]; then
  exit 0
fi

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
    # Classify the last assistant message to decide if notification is warranted
    TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // ""')
    CLASSIFY_SCRIPT="$HOME/.claude/hooks/classify-notification.sh"

    if [[ -x "$CLASSIFY_SCRIPT" ]]; then
      RESULT=$("$CLASSIFY_SCRIPT" "$TRANSCRIPT_PATH")
      SHOULD_NOTIFY=$(echo "$RESULT" | jq -r '.notify')
      if [[ "$SHOULD_NOTIFY" == "false" ]]; then
        echo "$(date -Iseconds) SKIPPED idle_prompt (classified as routine)" >> /tmp/claude-notify-debug.log
        exit 0
      fi
      SUBTITLE=$(echo "$RESULT" | jq -r '.subtitle // "Needs Input"')
      SUMMARY=$(echo "$RESULT" | jq -r '.summary // "Awaiting your input"')
    else
      SUBTITLE="Needs Input"
      SUMMARY="${MESSAGE:-Awaiting your input}"
    fi

    terminal-notifier \
      -title "$TITLE" \
      -subtitle "$SUBTITLE" \
      -message "$SUMMARY" \
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
