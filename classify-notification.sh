#!/bin/bash
# Reads the last assistant message from a Claude Code transcript and classifies
# whether it warrants interrupting the user with a notification.
#
# Usage: classify-notification.sh <transcript_path>
# Output: JSON on stdout: {"notify": bool, "subtitle": "...", "summary": "..."}

set -euo pipefail

DEFAULT='{"notify":true,"subtitle":"Needs Input","summary":"Awaiting your input"}'
TRANSCRIPT_PATH="${1:-}"

if [[ -z "$TRANSCRIPT_PATH" || ! -f "$TRANSCRIPT_PATH" ]]; then
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

NOTIFY = true when Claude:
- Asks a question or needs the user to make a decision
- Implemented or built something substantial (new feature, refactor, bug fix with code changes)
- Encountered an error, failure, or problem that needs attention
- Finished analysis, investigation, or research with results to share

NOTIFY = false when Claude:
- Ran a routine git/CLI operation (committed, pushed, created a PR, merged, rebased)
- Confirmed a trivial action (saved a file, deleted a file, ran a formatter)
- Gave a brief status acknowledgment with no meaningful content

For subtitle, use short labels like: "Question", "Feature Done", "Error Found", "Analysis Ready", "Bug Fixed", "Review Ready"
For summary, write naturally and concisely. Describe the outcome or question directly. Do not start with "Claude".'

DEBUG_LOG="/tmp/claude-classify-debug.log"

CLASSIFICATION=$(printf '%s' "$LAST_TEXT" \
  | CLAUDECODE="" claude -p \
      --model haiku \
      --no-session-persistence \
      --tools "" \
      --system-prompt "$SYSTEM_PROMPT" \
    2>"$DEBUG_LOG") || true

echo "$(date -Iseconds) raw_output=$(printf '%s' "$CLASSIFICATION" | head -c 500)" >> "$DEBUG_LOG"

# Strip markdown code fences if present
CLASSIFICATION=$(echo "$CLASSIFICATION" | sed '/^```/d')

# Validate the response is JSON with the required field
if echo "$CLASSIFICATION" | jq -e 'has("notify")' >/dev/null 2>&1; then
  echo "$CLASSIFICATION" | jq -c '.'
else
  # Classification failed or returned invalid JSON — default to notifying
  echo "$(date -Iseconds) FALLBACK jq_parse_failed" >> "$DEBUG_LOG"
  echo "$DEFAULT"
fi
