#!/usr/bin/env bash

set -euo pipefail

REPO_URL="${TYCHO_REPO_URL:-https://github.com/firewalker06/tycho.git}"
TARGET_DIR="${TYCHO_DIR:-tycho}"

script_path="${BASH_SOURCE[0]:-}"
if [[ -n "$script_path" && -f "$script_path" ]]; then
  script_dir="$(cd "$(dirname "$script_path")" && pwd)"
  if [[ -x "$script_dir/bin/setup" ]]; then
    exec "$script_dir/bin/setup" "$@"
  fi
fi

if [[ -x "bin/setup" && -f "Gemfile" ]]; then
  exec "bin/setup" "$@"
fi

if ! command -v git >/dev/null 2>&1; then
  echo "FAIL: git is required for the one-line Tycho installer." >&2
  echo "Install git, or clone $REPO_URL manually and run bin/setup." >&2
  exit 1
fi

if [[ -d "$TARGET_DIR/.git" ]]; then
  echo "INFO: Updating existing $TARGET_DIR checkout"
  git -C "$TARGET_DIR" pull --ff-only
elif [[ -e "$TARGET_DIR" ]]; then
  echo "FAIL: $TARGET_DIR already exists but is not a git checkout." >&2
  echo "Set TYCHO_DIR to another path or remove the existing file/directory." >&2
  exit 1
else
  echo "INFO: Cloning Tycho into $TARGET_DIR"
  git clone "$REPO_URL" "$TARGET_DIR"
fi

cd "$TARGET_DIR"
exec "bin/setup" "$@"
