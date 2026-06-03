#!/bin/bash
# OPS-131/OPS-150: TaskCompleted gate — ensures verification evidence exists before
# a task can be marked complete.
#
# Migrated to native JSON permissionDecision protocol (OPS-150).
# Always exits 0. Returns JSON on stdout with permissionDecision allow/deny.
# Note: This hook fires on TaskCompleted events but uses PreToolUse-style output
# since it gates tool usage.

VERIFY_DIR="${HOME}/.claude/gates"
mkdir -p "$VERIFY_DIR"

# Read the task info from stdin (Claude Code pipes hook input JSON)
TASK_INFO=$(cat)

# If this is a JUDGE verification task, always allow completion
if echo "$TASK_INFO" | grep -qi "judge\|verif"; then
  echo '{"continue":true,"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
  exit 0
fi

# If this is a PLANNER task, always allow completion
if echo "$TASK_INFO" | grep -qi "planner\|plan"; then
  echo '{"continue":true,"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
  exit 0
fi

# For WORKER tasks, check if plan was posted
if echo "$TASK_INFO" | grep -qi "worker\|implement"; then
  if [ ! -f "${HOME}/.claude/gates/sentinel-plan-posted" ]; then
    echo '{"continue":true,"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"WORKER task cannot complete without a PLAN note. Post PLAN note first."}}'
    exit 0
  fi
fi

# Default: allow
echo '{"continue":true,"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
exit 0
