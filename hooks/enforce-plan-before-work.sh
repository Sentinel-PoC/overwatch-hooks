#!/bin/bash
# OPS-131/OPS-150: Workflow gate — blocks WORKER edits until a PLAN note exists.
# Used as a PreToolUse hook on Edit/Write, scoped to worker agent sessions.
#
# Migrated to native JSON permissionDecision protocol (OPS-150).
# Always exits 0. Returns JSON on stdout with permissionDecision allow/deny.

PLAN_DIR="${HOME}/.claude/gates"
mkdir -p "$PLAN_DIR"
PLAN_FILE="${PLAN_DIR}/sentinel-plan-posted"

# Read stdin (hook input JSON) — consumed but not needed for this gate
cat > /dev/null

if [ -f "$PLAN_FILE" ]; then
  # Plan exists — allow edits
  echo '{"continue":true,"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
  exit 0
fi

# No plan posted — deny with reason
echo '{"continue":true,"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"No PLAN note confirmed. The PLANNER must post a PLAN note to the Plane issue before WORKER can make changes. Once posted, write the issue ID to ~/.claude/gates/sentinel-plan-posted to unlock edits."}}'
exit 0
