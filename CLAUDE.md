# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

macOS desktop notification hooks for Claude Code. Sends native notifications (via `terminal-notifier`) when Claude needs attention — waiting for input, requesting permissions, or completing tasks. Notifications are suppressed when the user is already focused on the relevant terminal session.

Two terminal variants are supported:
- **Warp** (`notify.sh`, `track-user-focus.sh`, `activate-warp-session.sh`) — app-level focus detection only (Warp has no AppleScript dictionary)
- **iTerm** (`notify-iterm.sh`, `track-user-focus-iterm.sh`, `activate-iterm-session.sh`) — per-session focus detection and activation via iTerm's AppleScript API using `ITERM_SESSION_ID`

## How it works

1. **Focus tracking** (`track-user-focus*.sh`): Runs on prompt submit (via Claude Code hooks) to record whether the user was looking at the terminal. Writes focus state + timestamp to `/tmp/claude-focus-*`.
2. **Notification** (`notify*.sh`): Runs on Claude Code notification/permission events. Reads JSON from stdin (`notification_type`, `message`), checks if the terminal is currently focused, and sends a `terminal-notifier` notification if not. Clicking the notification runs the activate script.
3. **Activation** (`activate-*-session.sh`): Brings the correct terminal window/session to the foreground when the user clicks a notification.

## Installation

`./install.sh` symlinks all hook scripts into `~/.claude/hooks/`. Hook configuration (which events trigger which scripts) is done in Claude Code's `settings.json` — see `hooks-iterm.json` for an iTerm example.

## Dependencies

- `jq` — JSON parsing in notification scripts
- `terminal-notifier` — macOS notification delivery (install via `brew install terminal-notifier`)
- `osascript` — macOS AppleScript for focus detection and window activation

## Notification types and sounds

| `notification_type`              | Subtitle           | Sound |
|----------------------------------|--------------------| ------|
| `idle_prompt`                    | Needs Input        | Blow  |
| `tool_complete` / `agent_complete` | Done            | Glass |
| `permission_prompt`              | Permission Needed (or "Plan Ready" if message contains "plan", iTerm only) | Basso |
| unknown/default                  | *(none)*           | Pop   |

## Debug logging

iTerm variant logs raw hook payloads to `/tmp/claude-notify-debug.log`.
