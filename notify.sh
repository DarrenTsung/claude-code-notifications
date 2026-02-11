#!/bin/bash
# Claude Code notification hook that differentiates between notification types

# Read JSON from stdin
INPUT=$(cat)

# Parse fields using jq
HOOK_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // ""')
NOTIFICATION_TYPE=$(echo "$INPUT" | jq -r '.notification_type // "unknown"')
MESSAGE=$(echo "$INPUT" | jq -r '.message // ""')

# Skip PermissionRequest events — Claude Code always follows them with a
# Notification event that has proper notification_type and message.
if [[ "$HOOK_EVENT" == "PermissionRequest" ]]; then
  exit 0
fi

ACTIVATE_SCRIPT="$HOME/.claude/hooks/activate-warp-session.sh"
TITLE="Claude Code"

# Skip notification if Warp is the frontmost app.
# Warp has no AppleScript dictionary, so we can only check app-level focus,
# not per-session focus. The process name in System Events is "stable".
IS_FOCUSED=$(osascript -e "
  tell application \"System Events\"
    set frontApp to name of first application process whose frontmost is true
    if frontApp is \"stable\" then return true
  end tell
  return false
" 2>/dev/null)

if [[ "$IS_FOCUSED" == "true" ]]; then
  exit 0
fi

case "$NOTIFICATION_TYPE" in
  "idle_prompt")
    # Claude is waiting for user input
    terminal-notifier \
      -title "$TITLE" \
      -subtitle "Needs Input" \
      -message "${MESSAGE:-Awaiting your input}" \
      -sound Blow \
      -execute "$ACTIVATE_SCRIPT"
    ;;
  "tool_complete"|"agent_complete")
    # Task completed
    terminal-notifier \
      -title "$TITLE" \
      -subtitle "Done" \
      -message "${MESSAGE:-Task completed}" \
      -sound Glass \
      -execute "$ACTIVATE_SCRIPT"
    ;;
  "permission_prompt")
    # Needs permission approval
    terminal-notifier \
      -title "$TITLE" \
      -subtitle "Permission Needed" \
      -message "${MESSAGE:-Approval required}" \
      -sound Basso \
      -execute "$ACTIVATE_SCRIPT"
    ;;
  *)
    # Default/unknown notification
    terminal-notifier \
      -title "$TITLE" \
      -message "${MESSAGE:-Notification}" \
      -sound Pop \
      -execute "$ACTIVATE_SCRIPT"
    ;;
esac
