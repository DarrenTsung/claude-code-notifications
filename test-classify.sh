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

classify "Waiting for sub-agents" \
  'Two answer agents running in parallel:
  1. ML job triggers — investigating what caused mlFileChunksIndexJob (+30%) and fileAnalyzerJob (3x) volume changes via Statsig, LaunchDarkly, and code
  2. Metrics verification — checking whether the Statsig gate increased overflow rate, and whether the Feb 27 fixes resolved the regression

  Waiting for both to complete.' \
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
  false

classify "Found a bug" \
  'I found the issue — there'\''s a race condition in the connection pool. When two requests arrive simultaneously, they can both grab the same connection because the lock is released between the check and the acquire. I'\''ve added a mutex to fix this.' \
  true

classify "Error encountered" \
  'I ran into an error trying to build the project. The TypeScript compiler is reporting 12 type errors in the auth module, mostly related to the new User type missing the `refreshToken` field.' \
  true

classify "Investigation with options to choose" \
  'Check-in: Major discovery — both leading hypotheses refuted.

  Notebook: https://app.datadoghq.com/notebook/13999109

  What changed: Code review eliminated the two strongest candidates:

  1. multiplayer_skip_connection_promise flag — REFUTED. Both code paths (old and new) call the same create_connection / destroy_connection logic. The flag is a latency
  optimization that skips a TypeScript round-trip promise, not a resource management change. No leak mechanism exists in either path. The megaprocess also started climbing at 8
  AM PT when the flag was only at 10%, further weakening this hypothesis.
  2. get_dirty_documents() query limit removal — REFUTED. The LaunchDarkly flag was already set to 0 (unlimited) in production before the code was removed — the code change was
  a no-op. The data structures are tiny (~50-100 bytes per entry) with bounded result sets.

  New findings that reshape the picture:
  - The megaprocess started climbing at 8 AM PT Wed Feb 18 — 8 hours before the container-level onset at 4 PM PT. This earlier timeline predates both the flag ramp and the
  container metric divergence.
  - Node.js heap dropped 87% (870 MB → 112 MB) post-Deploy 1, suggesting work may have shifted from Node to Rust, which complicates the baseline.

  Remaining candidates:
  - 236cb75 (reconnect metric change) — calls get_cached_changes_after_seqnum() even when journaled reconnect isn'\''t enabled, potentially cloning cached data unnecessarily
  - multiplayer_rust_file_restore at 33% rollout — Rust file restore path may have different memory characteristics
  - Other Deploy 1 Rust changes from the Feb 17 window

  The investigation is at a pivot point. How would you like to proceed?
  - Continue — keep the review loop going to investigate the remaining candidates
  - Redirect — you have specific ideas about what to investigate
  - Stop — publish as-is with root cause inconclusive

  (Notebook writer idle — waiting for your direction before continuing.)' \
  true

# --- Edge cases: short/ambiguous messages that previously broke Haiku ---

classify "Short acknowledgment - Got it" \
  'Got it!' \
  false

classify "Short acknowledgment - Done" \
  'Done!' \
  false

classify "Short acknowledgment - OK" \
  'OK, sounds good.' \
  false

classify "Review complete, no question" \
  'All reviewers have shut down. The full review summary is above — let me know if you have any questions about the PR or want to dig into anything specific.' \
  false

# --- Summary ---

echo ""
echo "=== Results: $pass passed, $fail failed ==="
exit $((fail > 0 ? 1 : 0))
