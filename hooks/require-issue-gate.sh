#!/bin/bash
# OPS-131/OPS-150: Pre-flight gate — ensures a Plane issue ID is tracked before file modifications.
# Used as a PreToolUse hook on Edit/Write tools.
#
# Migrated to native JSON permissionDecision protocol (OPS-150).
# Always exits 0. Returns JSON on stdout with permissionDecision allow/deny.

ISSUE_DIR="${HOME}/.claude/gates"
mkdir -p "$ISSUE_DIR"
ISSUE_FILE="${ISSUE_DIR}/sentinel-issue-id"

# Read stdin (hook input JSON) — consumed but not needed for this gate
cat > /dev/null

if [ -f "$ISSUE_FILE" ]; then
  ISSUE_ID=$(head -1 "$ISSUE_FILE" | tr -d '[:space:]')
  if [[ "$ISSUE_ID" =~ ^(OPS|SEC|COMP|HAIST|DEV)-[0-9]+$ ]]; then
    # Valid issue ID found — allow
    echo '{"continue":true,"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
    exit 0
  fi
fi

# No valid issue ID — deny with reason
echo '{"continue":true,"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"No Plane issue ID set. Before modifying files, write your issue ID to ~/.claude/gates/sentinel-issue-id (e.g., echo OPS-42 > ~/.claude/gates/sentinel-issue-id). This is required by the Overwatch agent framework."}}'
exit 0
