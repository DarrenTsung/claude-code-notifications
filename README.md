# claude-code-notifications

macOS desktop notifications for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Get notified when Claude needs input, finishes a task, or requests permissions — unless you're already looking at the terminal.

Supports **iTerm** (per-session focus detection) and **Warp** (app-level focus detection).

## Setup

Install dependencies:

```sh
brew install jq terminal-notifier
```

Symlink hook scripts into `~/.claude/hooks/`:

```sh
./install.sh
```

Then add hook configuration to your Claude Code `settings.json`. See `hooks-iterm.json` for an iTerm example.

## How it works

1. **Focus tracking** — On prompt submit, records whether the terminal is focused.
2. **Notification** — On Claude events, sends a `terminal-notifier` notification if the terminal isn't focused.
3. **Activation** — Clicking the notification brings the correct terminal/session to the foreground.
