# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

macOS desktop notification hooks for Claude Code. Sends native notifications (via `terminal-notifier`) when Claude needs attention — waiting for input, requesting permissions, or completing tasks. Notifications are suppressed when the user is already focused on the relevant terminal session.

Two terminal variants are supported:
- **Warp** (`notify.sh`, `track-user-focus.sh`, `activate-warp-session.sh`) — app-level focus detection only (Warp has no AppleScript dictionary)
- **iTerm** (`notify-iterm.sh`, `track-user-focus-iterm.sh`, `activate-iterm-session.sh`) — per-session focus detection and activation via iTerm's AppleScript API using `ITERM_SESSION_ID`

## How it works

1. **Focus tracking** (`track-user-focus*.sh`): Runs on prompt submit (via Claude Code hooks) to record whether the user was looking at the terminal. Writes focus state + timestamp to `/tmp/claude-focus-*`.
2. **Notification** (`notify*.sh`): Runs on Claude Code `Notification` events (and, for the iTerm variant, `PermissionRequest` events). Reads JSON from stdin (`notification_type`, `message`, etc.), checks if the terminal is currently focused, and sends a `terminal-notifier` notification if not. Clicking the notification runs the activate script.
3. **Activation** (`activate-*-session.sh`): Brings the correct terminal window/session to the foreground when the user clicks a notification.

### Memory-write approvals (iTerm)

Memory saves use the `memory` tool and are normally auto-allowed, so they fire no `Notification`. To surface the rare case where a memory write *needs approval*, `notify-iterm.sh` is also wired to `PermissionRequest`:

- A `PermissionRequest` for `tool_name == "memory"` drops a short-lived marker at `/tmp/claude-notify-mem-<session_id>` describing the op (it does **not** notify — that would fire on every memory write).
- The follow-up generic `permission_prompt` `Notification` checks for a *fresh* marker (≤10s old) and, if found, labels the notification **Memory** with the op details instead of the generic "Permission Needed".

This means a memory notification fires *only when approval is actually needed*. Caveat: because `PermissionRequest` also fires for auto-allowed memory writes, an unrelated permission prompt that happens within 10s of a memory write could be mislabeled "Memory" (cosmetic only — the notification and click-to-activate still work correctly).

## Installation

`./install.sh` symlinks all hook scripts into `~/.claude/hooks/`. Hook configuration (which events trigger which scripts) is done in Claude Code's `settings.json` — see `hooks-iterm.json` for an iTerm example.

## Dependencies

- `jq` — JSON parsing in notification scripts
- `terminal-notifier` — macOS notification delivery (install via `brew install terminal-notifier`)
- `osascript` — macOS AppleScript for focus detection and window activation

## Notification types and sounds

The live `notification_type` enum emitted by Claude Code (from the CLI's
`Notification` hook `matcherMetadata`) is exactly: `permission_prompt`,
`idle_prompt`, `auth_success`, `elicitation_dialog`, `elicitation_complete`,
`elicitation_response`. Memory saves are autonomous (the `memory` tool writes
files directly) and do **not** emit a `Notification` event — they only surface
as a `permission_prompt` if the write isn't auto-allowed.

| `notification_type`              | Subtitle           | Sound | Notes |
|----------------------------------|--------------------|-------|-------|
| `idle_prompt`                    | *(classified)*     | Blow  | Routed through `classify-notification.sh`; routine pauses are suppressed |
| `elicitation_dialog`             | Needs Input        | Blow  | MCP/interactive tool opened an input form and is blocked |
| `permission_prompt`              | Permission Needed (or "Plan Ready" if message contains "plan", iTerm only) | Basso | |
| `skill_edit`                     | Skill Edit         | Funk  | Synthesized from a `PermissionRequest` Edit/Write under `/skills/` (requires the hook to be registered for `PermissionRequest`) |
| `auth_success` / `elicitation_complete` / `elicitation_response` | — | — | Suppressed: observability-only, no user action needed |
| `tool_complete` / `agent_complete` | Done             | Glass | Legacy/unused — not emitted by current Claude Code |
| unknown/default                  | *(none)*           | Pop   | Fallback for any future type |

## Debug logging

iTerm variant logs raw hook payloads to `/tmp/claude-notify-debug.log`.
