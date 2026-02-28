#!/bin/bash
# Test script for classify-notification.sh
# Creates fake transcript files with different assistant messages and runs classification.
#
# Usage: ./test-classify.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLASSIFY="$SCRIPT_DIR/classify-notification.sh"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

pass=0
fail=0

classify() {
  local label="$1"
  local message="$2"
  local expect_notify="$3" # "true" or "false"

  # Build a minimal transcript JSONL with one assistant message
  local transcript="$TMPDIR/test-$RANDOM.jsonl"
  jq -nc --arg msg "$message" '{
    type: "assistant",
    message: {
      role: "assistant",
      content: [{ type: "text", text: $msg }]
    }
  }' > "$transcript"

  echo "---"
  echo "TEST: $label"
  echo "  Message: ${message:0:80}$([ ${#message} -gt 80 ] && echo '...')"
  echo "  Expect notify=$expect_notify"

  RESULT=$(CLAUDECODE="" "$CLASSIFY" "$transcript" 2>/dev/null)
  GOT_NOTIFY=$(echo "$RESULT" | jq -r '.notify')
  GOT_SUBTITLE=$(echo "$RESULT" | jq -r '.subtitle // ""')
  GOT_SUMMARY=$(echo "$RESULT" | jq -r '.summary // ""')

  if [[ "$GOT_NOTIFY" == "$expect_notify" ]]; then
    echo "  PASS (notify=$GOT_NOTIFY)"
    ((pass++))
  else
    echo "  FAIL (expected notify=$expect_notify, got notify=$GOT_NOTIFY)"
    ((fail++))
  fi
  echo "  subtitle: $GOT_SUBTITLE"
  echo "  summary:  $GOT_SUMMARY"
}

echo "=== classify-notification.sh tests ==="
echo ""

# --- Should NOT notify (routine) ---

classify "Pushed to remote" \
  'Pushed to `main`.' \
  false

classify "Committed changes" \
  'I'\''ve committed the changes with message "fix: update error handling".' \
  false

classify "Created a PR" \
  'Created PR #42: https://github.com/user/repo/pull/42' \
  false

classify "Simple confirmation" \
  'Done. The file has been saved.' \
  false

# --- Should notify (questions) ---

classify "Asking a question" \
  'I found two approaches for this. Should I use a Redis cache or an in-memory LRU cache? The Redis approach is more scalable but adds a dependency.' \
  true

classify "Needs a decision" \
  'The test is failing because the API response format changed. Do you want me to update the test expectations or fix the API handler to match the old format?' \
  true

# --- Should notify (significant work) ---

classify "Implemented a feature" \
  'I'\''ve implemented the user authentication system. The changes include a new JWT middleware, login/logout endpoints, and a refresh token flow. The middleware validates tokens on every request and returns 401 for expired sessions.' \
  true

classify "Found a bug" \
  'I found the issue — there'\''s a race condition in the connection pool. When two requests arrive simultaneously, they can both grab the same connection because the lock is released between the check and the acquire. I'\''ve added a mutex to fix this.' \
  true

classify "Error encountered" \
  'I ran into an error trying to build the project. The TypeScript compiler is reporting 12 type errors in the auth module, mostly related to the new User type missing the `refreshToken` field.' \
  true

# --- Summary ---

echo ""
echo "=== Results: $pass passed, $fail failed ==="
exit $((fail > 0 ? 1 : 0))
