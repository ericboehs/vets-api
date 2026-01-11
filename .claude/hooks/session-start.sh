#!/bin/bash
set -euo pipefail

# Only run in remote Claude Code environment
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

echo "=== Claude Code SessionStart Hook ==="

# Run the shared dev-setup script
cd "$CLAUDE_PROJECT_DIR"
./scripts/dev-setup.sh --parallel-dbs

# Set up PATH for the session
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo 'export PATH="/opt/rbenv/versions/3.3.6/bin:/usr/bin:$PATH"' >> "$CLAUDE_ENV_FILE"
fi

echo "=== Claude Code environment ready ==="
