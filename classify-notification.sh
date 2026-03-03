#!/bin/bash
# Reads the last assistant message from a Claude Code transcript and classifies
# whether it warrants interrupting the user with a notification.
#
# Usage: classify-notification.sh <transcript_path>
# Output: JSON on stdout: {"notify": bool, "subtitle": "...", "summary": "..."}
# Logs:   /tmp/claude-classify-debug.log

set -euo pipefail

DEBUG_LOG="/tmp/claude-classify-debug.log"
DEFAULT='{"notify":true,"subtitle":"Needs Input","summary":"Awaiting your input"}'
TRANSCRIPT_PATH="${1:-}"

if [[ -z "$TRANSCRIPT_PATH" || ! -f "$TRANSCRIPT_PATH" ]]; then
  echo "$(date -Iseconds) NO_TRANSCRIPT path=${TRANSCRIPT_PATH:-<empty>}" >> "$DEBUG_LOG"
  echo "$DEFAULT"
  exit 0
fi

# Extract the last assistant message with text content.
# Only check the tail of the file for performance.
LAST_TEXT=$(tail -50 "$TRANSCRIPT_PATH" \
  | jq -rs '
      [ .[]
        | select(.type == "assistant")
        | { text: [ .message.content[] | select(.type == "text") | .text ] | join("\n") }
        | select(.text | length > 0)
      ] | last | .text // empty
    ' 2>/dev/null)

if [[ -z "$LAST_TEXT" ]]; then
  echo "$(date -Iseconds) NO_TEXT transcript=$TRANSCRIPT_PATH" >> "$DEBUG_LOG"
  echo "$DEFAULT"
  exit 0
fi

# Truncate to keep classification fast and cheap
LAST_TEXT="${LAST_TEXT:0:3000}"

# Classify with Claude haiku.
# CLAUDECODE="" prevents recursive hook invocation.
SYSTEM_PROMPT='You classify Claude Code notification messages to decide if the user should be interrupted with a macOS desktop notification.

Respond with ONLY a JSON object (no markdown fences, no explanation):
{"notify": true/false, "subtitle": "2-4 word label", "summary": "concise notification text"}

IMPORTANT: If the message asks a question, presents options, or requests a decision, ALWAYS set notify=true regardless of other signals.

NOTIFY = true when Claude:
- Asks a question, presents options, or needs the user to make a decision (HIGHEST PRIORITY — overrides everything else)
- Implemented or built something substantial (new feature, refactor, bug fix with code changes)
- Encountered an error, failure, or problem that needs attention
- Finished analysis, investigation, or research with results to share

NOTIFY = false when Claude:
- Ran a routine git/CLI operation (committed, pushed, created a PR, merged, rebased)
- Confirmed a trivial action (saved a file, deleted a file, ran a formatter)
- Gave a brief status acknowledgment with no meaningful content
- Is still working and waiting for sub-tasks/agents to complete with NO question asked (e.g. "launched 3 agents, waiting for results")

For subtitle, use short labels like: "Question", "Feature Done", "Error Found", "Analysis Ready", "Bug Fixed", "Review Ready"
For summary, write naturally and concisely. Describe the outcome or question directly. Do not start with "Claude".'

STDERR_LOG=$(mktemp)
CLASSIFICATION=$(printf '%s' "$LAST_TEXT" \
  | CLAUDECODE="" claude -p \
      --model haiku \
      --no-session-persistence \
      --tools "" \
      --system-prompt "$SYSTEM_PROMPT" \
    2>"$STDERR_LOG") || true

# Strip markdown code fences if present
CLASSIFICATION=$(echo "$CLASSIFICATION" | sed '/^```/d')

# Log the full decision
{
  echo "$(date -Iseconds) === CLASSIFY ==="
  echo "  message: ${LAST_TEXT:0:200}$([ ${#LAST_TEXT} -gt 200 ] && echo '...')"
  if echo "$CLASSIFICATION" | jq -e 'has("notify")' >/dev/null 2>&1; then
    echo "  result:  $(echo "$CLASSIFICATION" | jq -c '.')"
    echo "  action:  $(echo "$CLASSIFICATION" | jq -r 'if .notify then "NOTIFY" else "SKIP" end')"
  else
    echo "  result:  <invalid json> $CLASSIFICATION"
    echo "  stderr:  $(cat "$STDERR_LOG")"
    echo "  action:  NOTIFY (fallback)"
  fi
} >> "$DEBUG_LOG"
rm -f "$STDERR_LOG"

# Validate the response is JSON with the required field
if echo "$CLASSIFICATION" | jq -e 'has("notify")' >/dev/null 2>&1; then
  echo "$CLASSIFICATION" | jq -c '.'
else
  echo "$DEFAULT"
fi
