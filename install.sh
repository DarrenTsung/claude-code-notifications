#!/bin/bash
# Symlinks notification hook scripts into ~/.claude/hooks/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS_DIR="$HOME/.claude/hooks"

mkdir -p "$HOOKS_DIR"

SCRIPTS=(
  activate-iterm-session.sh
  activate-warp-session.sh
  classify-notification.sh
  notify-iterm.sh
  notify.sh
  track-user-focus-iterm.sh
  track-user-focus.sh
)

for script in "${SCRIPTS[@]}"; do
  src="$SCRIPT_DIR/$script"
  dest="$HOOKS_DIR/$script"

  if [[ ! -f "$src" ]]; then
    echo "SKIP $script (not found)"
    continue
  fi

  if [[ -L "$dest" ]]; then
    rm "$dest"
  elif [[ -e "$dest" ]]; then
    echo "SKIP $script (non-symlink already exists at $dest)"
    continue
  fi

  ln -s "$src" "$dest"
  echo "  OK $script"
done

echo "Done."
