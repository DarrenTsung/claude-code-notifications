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

# Calls claude with the given model and writes the parsed classification to stdout.
# Returns 0 if valid JSON, 1 otherwise. Logs stderr to the given file.
classify_with_model() {
  local model="$1"
  local stderr_file="$2"
  local raw
  raw=$(printf '%s' "$LAST_TEXT" \
    | CLAUDECODE="" claude -p \
        --model "$model" \
        --no-session-persistence \
        --tools "" \
        --system-prompt "$SYSTEM_PROMPT" \
      2>"$stderr_file") || true
  # Strip markdown code fences if present
  raw=$(echo "$raw" | sed '/^```/d')
  # Try parsing as-is first, then extract first JSON object if there's trailing text
  local parsed
  if parsed=$(echo "$raw" | jq -ce 'select(has("notify"))' 2>/dev/null); then
    echo "$parsed"
    return 0
  elif parsed=$(echo "$raw" | grep -o '{[^}]*}' | head -1 | jq -ce 'select(has("notify"))' 2>/dev/null); then
    echo "$parsed"
    return 0
  else
    echo "$raw"
    return 1
  fi
}

STDERR_LOG=$(mktemp)
CLASSIFICATION=""
USED_MODEL="haiku"

if CLASSIFICATION=$(classify_with_model haiku "$STDERR_LOG"); then
  : # Haiku succeeded
else
  # Log the Haiku failure, then retry with Sonnet
  {
    echo "$(date -Iseconds) === CLASSIFY (haiku failed, retrying with sonnet) ==="
    echo "  message: ${LAST_TEXT:0:200}$([ ${#LAST_TEXT} -gt 200 ] && echo '...')"
    echo "  haiku_result: <invalid> $CLASSIFICATION"
    echo "  haiku_stderr: $(cat "$STDERR_LOG")"
  } >> "$DEBUG_LOG"

  USED_MODEL="sonnet (retry)"
  if ! CLASSIFICATION=$(classify_with_model sonnet "$STDERR_LOG"); then
    USED_MODEL="sonnet (retry, also failed)"
  fi
fi

# Log the final decision
{
  echo "$(date -Iseconds) === CLASSIFY ($USED_MODEL) ==="
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

# Output valid classification or fall back to default
if echo "$CLASSIFICATION" | jq -e 'has("notify")' >/dev/null 2>&1; then
  echo "$CLASSIFICATION" | jq -c '.'
else
  echo "$DEFAULT"
fi
