#!/bin/bash
# uninstall.sh - Remove clank scripts, skills, and config
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "== Clank Uninstaller =="
echo ""

read -p "Bin directory to clean [$HOME/bin]: " BIN_DIR
BIN_DIR="${BIN_DIR:-$HOME/bin}"

# Remove symlinks (only if they point back to this repo)
for script in "$SCRIPT_DIR"/bin/*; do
  name=$(basename "$script")
  target="$BIN_DIR/$name"
  if [ -L "$target" ] && [ "$(readlink "$target")" = "$script" ]; then
    rm "$target"
    echo "  Removed: $target"
  fi
done

# Remove skills
SKILLS_DIR="$HOME/.claude/skills"
for skill_dir in "$SCRIPT_DIR"/skills/*/; do
  skill_name=$(basename "$skill_dir")
  if [ -d "$SKILLS_DIR/$skill_name" ]; then
    rm -rf "$SKILLS_DIR/$skill_name"
    echo "  Removed skill: $skill_name"
  fi
done

# Remove config
if [ -f "$HOME/.clankrc" ]; then
  read -p "Remove ~/.clankrc? [y/N] " -n 1 -r
  echo ""
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    rm "$HOME/.clankrc"
    echo "  Removed: ~/.clankrc"
  fi
fi

echo ""
echo "Uninstall complete."
