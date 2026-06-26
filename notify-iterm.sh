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

# For PermissionRequest events, only send a notification if it's a skill edit.
# Other PermissionRequests are skipped — Claude Code follows them with a
# Notification event that has proper notification_type and message.
if [[ "$HOOK_EVENT" == "PermissionRequest" ]]; then
  TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""')
  FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')
  if [[ ("$TOOL_NAME" == "Edit" || "$TOOL_NAME" == "Write") && "$FILE_PATH" == *"/skills/"* ]]; then
    NOTIFICATION_TYPE="skill_edit"
    MESSAGE="$TOOL_NAME: ${FILE_PATH##*/skills/}"
  elif [[ "$TOOL_NAME" == "memory" ]]; then
    # Memory writes are normally auto-allowed and fire NO Notification. When one
    # genuinely needs approval, Claude Code follows this PermissionRequest with a
    # generic `permission_prompt` Notification. We don't notify here (that would
    # fire on every memory write); instead we drop a short-lived marker describing
    # the op. The permission_prompt handler below labels its notification "Memory"
    # iff a *fresh* marker exists — so we only ever notify when approval is actually
    # needed. If the write is auto-allowed, no permission_prompt follows and the
    # marker simply expires unused.
    CLAUDE_SESSION=$(echo "$INPUT" | jq -r '.session_id // "unknown"')
    MEM_CMD=$(echo "$INPUT" | jq -r '.tool_input.command // ""')
    MEM_PATH=$(echo "$INPUT" | jq -r '.tool_input.path // ""')
    MEM_DESC="${MEM_CMD:-write}${MEM_PATH:+ ${MEM_PATH##*/}}"
    printf '%s' "$MEM_DESC" > "/tmp/claude-notify-mem-${CLAUDE_SESSION}"
    echo "$(date -Iseconds) MEMORY PermissionRequest marker: $MEM_DESC" >> /tmp/claude-notify-debug.log
    exit 0
  elif [[ "$TOOL_NAME" == "Bash" ]]; then
    # A Bash command reached the permission engine, which means the PreToolUse
    # approve-hook did NOT auto-approve it (it auto-allows ~98% of commands, and
    # an "allow" decision fires no PermissionRequest). So a Bash PermissionRequest
    # means manual approval is genuinely needed — e.g. Claude flagged command
    # substitution `$(...)` / backticks, which it forces a prompt for even when a
    # hook or rule would otherwise allow the command. The follow-up
    # `permission_prompt` Notification is unreliable for these (often never
    # emitted), so notify here off the deterministic PermissionRequest. Drop a
    # short-lived marker so that if the follow-up Notification *does* fire, the
    # permission_prompt handler below skips it instead of double-notifying.
    CLAUDE_SESSION=$(echo "$INPUT" | jq -r '.session_id // "unknown"')
    touch "/tmp/claude-notify-permreq-${CLAUDE_SESSION}"
    BASH_DESC=$(echo "$INPUT" | jq -r '.tool_input.description // ""')
    if [[ -n "$BASH_DESC" ]]; then
      MESSAGE="Approve: $BASH_DESC"
    else
      BASH_CMD=$(echo "$INPUT" | jq -r '.tool_input.command // ""')
      BASH_FIRST=$(printf '%s\n' "$BASH_CMD" | grep -vE '^[[:space:]]*(#|$)' | head -1)
      MESSAGE="Approve: ${BASH_FIRST:0:100}"
    fi
    NOTIFICATION_TYPE="permission_prompt"
    # fall through to the focus/dedup checks and the permission_prompt case below
  else
    exit 0
  fi
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

# Dedup: skip if we already sent this exact notification for this session
# *within the last DEDUP_WINDOW seconds*. Uses a per-session file storing the
# hash of the last notification payload. The hash covers notification_type +
# message, so terminal-redraw re-emits (which arrive within a second or two of
# the original) are suppressed. The time window is essential: permission and
# idle prompts carry a constant message ("Claude needs your permission" /
# "Claude is waiting for your input"), so without it the *first* prompt in a
# session would suppress every later one with the same key for the whole
# session. Beyond the window, an identical key is treated as a genuinely new
# notification.
SESSION_HASH_ID="${SESSION_ID:-unknown}"
SESSION_HASH_ID="${SESSION_HASH_ID##*:}"
DEDUP_FILE="/tmp/claude-notify-dedup-${SESSION_HASH_ID}"
DEDUP_KEY=$(printf '%s\n%s' "$NOTIFICATION_TYPE" "$MESSAGE" | shasum -a 256 | cut -d' ' -f1)
DEDUP_WINDOW=10

if [[ -f "$DEDUP_FILE" ]] && [[ "$(cat "$DEDUP_FILE")" == "$DEDUP_KEY" ]]; then
  DEDUP_AGE=$(( $(date +%s) - $(stat -f %m "$DEDUP_FILE" 2>/dev/null || echo 0) ))
  if (( DEDUP_AGE <= DEDUP_WINDOW )); then
    echo "$(date -Iseconds) DEDUP $NOTIFICATION_TYPE (re-emit within ${DEDUP_WINDOW}s)" >> /tmp/claude-notify-debug.log
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
        echo "$(date -Iseconds) SKIPPED idle_prompt (classified as routine) result=$(echo "$RESULT" | jq -c '.')" >> /tmp/claude-notify-debug.log
        # Still record in dedup so we don't re-classify on redraw
        echo "$DEDUP_KEY" > "$DEDUP_FILE"
        exit 0
      fi
      SUBTITLE=$(echo "$RESULT" | jq -r '.subtitle // "Needs Input"')
      SUMMARY=$(echo "$RESULT" | jq -r '.summary // "Awaiting your input"')
      CLASSIFY_SOURCE="classified"
    else
      SUBTITLE="Needs Input"
      SUMMARY="${MESSAGE:-Awaiting your input}"
      CLASSIFY_SOURCE="no-classifier"
    fi

    echo "$(date -Iseconds) SENT idle_prompt ($CLASSIFY_SOURCE) subtitle=\"$SUBTITLE\" message=\"$SUMMARY\"" >> /tmp/claude-notify-debug.log
    echo "$DEDUP_KEY" > "$DEDUP_FILE"
    terminal-notifier \
      -title "$TITLE" \
      -subtitle "$SUBTITLE" \
      -message "$SUMMARY" \
      -sound Blow \
      -execute "$ACTIVATE_SCRIPT $SESSION_ID"
    ;;
  "elicitation_dialog")
    # An MCP server (or interactive tool) has opened an input form and is
    # blocked waiting on you. This is the newest "needs your attention" type —
    # treat it like idle_prompt but without the classifier (an open form always
    # warrants a ping).
    echo "$DEDUP_KEY" > "$DEDUP_FILE"
    echo "$(date -Iseconds) SENT elicitation_dialog message=\"$MESSAGE\"" >> /tmp/claude-notify-debug.log
    terminal-notifier \
      -title "$TITLE" \
      -subtitle "Needs Input" \
      -message "${MESSAGE:-Claude needs your input}" \
      -sound Blow \
      -execute "$ACTIVATE_SCRIPT $SESSION_ID"
    ;;
  "elicitation_complete"|"elicitation_response"|"auth_success")
    # Observability-only events: an elicitation form was submitted/resolved, or
    # login succeeded. No user action is required, so suppress them — otherwise
    # they fall through to the default case and fire a noisy notification.
    # (Record in dedup so a terminal redraw doesn't re-trigger anything.)
    echo "$DEDUP_KEY" > "$DEDUP_FILE"
    echo "$(date -Iseconds) SKIPPED $NOTIFICATION_TYPE (observability-only, no action needed)" >> /tmp/claude-notify-debug.log
    exit 0
    ;;
  "tool_complete"|"agent_complete")
    # NOTE: these are NOT emitted by current Claude Code (the live notification_type
    # enum is permission_prompt/idle_prompt/auth_success/elicitation_*). Kept as a
    # harmless legacy branch in case an older client or the SDK emits them.
    echo "$DEDUP_KEY" > "$DEDUP_FILE"
    terminal-notifier \
      -title "$TITLE" \
      -subtitle "Done" \
      -message "${MESSAGE:-Task completed}" \
      -sound Glass \
      -execute "$ACTIVATE_SCRIPT $SESSION_ID"
    ;;
  "skill_edit")
    echo "$DEDUP_KEY" > "$DEDUP_FILE"
    terminal-notifier \
      -title "$TITLE" \
      -subtitle "Skill Edit" \
      -message "${MESSAGE}" \
      -sound Funk \
      -execute "$ACTIVATE_SCRIPT $SESSION_ID"
    ;;
  "permission_prompt")
    # If a memory PermissionRequest fired moments ago (see the PermissionRequest
    # branch above), this prompt is the memory write asking for approval — label it.
    CLAUDE_SESSION=$(echo "$INPUT" | jq -r '.session_id // "unknown"')
    # If we already notified off the Bash PermissionRequest moments ago (see the
    # Bash branch above), this is the redundant follow-up Notification — skip it.
    PERMREQ_MARKER="/tmp/claude-notify-permreq-${CLAUDE_SESSION}"
    if [[ -f "$PERMREQ_MARKER" ]] && [[ "$HOOK_EVENT" == "Notification" ]]; then
      MARKER_AGE=$(( $(date +%s) - $(stat -f %m "$PERMREQ_MARKER" 2>/dev/null || echo 0) ))
      rm -f "$PERMREQ_MARKER"
      if (( MARKER_AGE <= 15 )); then
        echo "$DEDUP_KEY" > "$DEDUP_FILE"
        echo "$(date -Iseconds) SKIPPED permission_prompt (already notified via PermissionRequest)" >> /tmp/claude-notify-debug.log
        exit 0
      fi
    fi
    MEM_MARKER="/tmp/claude-notify-mem-${CLAUDE_SESSION}"
    MEM_LABELLED=false
    if [[ -f "$MEM_MARKER" ]]; then
      MARKER_AGE=$(( $(date +%s) - $(stat -f %m "$MEM_MARKER" 2>/dev/null || echo 0) ))
      if (( MARKER_AGE <= 10 )); then
        SUBTITLE="Memory"
        MESSAGE="Memory write needs approval: $(cat "$MEM_MARKER")"
        MEM_LABELLED=true
      fi
      rm -f "$MEM_MARKER"
    fi
    if [[ "$MEM_LABELLED" != "true" ]]; then
      if [[ "$MESSAGE" == *"plan"* ]]; then
        SUBTITLE="Plan Ready"
      else
        SUBTITLE="Permission Needed"
      fi
    fi
    echo "$DEDUP_KEY" > "$DEDUP_FILE"
    echo "$(date -Iseconds) SENT permission_prompt subtitle=\"$SUBTITLE\"" >> /tmp/claude-notify-debug.log
    terminal-notifier \
      -title "$TITLE" \
      -subtitle "$SUBTITLE" \
      -message "${MESSAGE:-Approval required}" \
      -sound Basso \
      -execute "$ACTIVATE_SCRIPT $SESSION_ID"
    ;;
  *)
    # Default/unknown notification
    echo "$DEDUP_KEY" > "$DEDUP_FILE"
    terminal-notifier \
      -title "$TITLE" \
      -message "${MESSAGE:-Notification}" \
      -sound Pop \
      -execute "$ACTIVATE_SCRIPT $SESSION_ID"
    ;;
esac
