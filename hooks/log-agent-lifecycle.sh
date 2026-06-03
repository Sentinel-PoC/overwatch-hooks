#!/usr/bin/env bash
# log-agent-lifecycle.sh — SubagentStart/SubagentStop audit logger
# Logs agent spawn/stop events to ~/.claude/gates/agent-lifecycle.log
# Returns {"continue":true} so agent operations are never blocked.
# OPS-151

set -euo pipefail

LOG_FILE="$HOME/.claude/gates/agent-lifecycle.log"

# Read JSON from stdin
INPUT=$(cat)

# Extract fields using python3 (available on all targets, no jq dependency)
read -r EVENT_NAME AGENT_TYPE SESSION_ID AGENT_ID CWD <<< "$(echo "$INPUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(
    d.get('hook_event_name', 'unknown'),
    d.get('agent_type', 'unknown'),
    d.get('session_id', 'unknown'),
    d.get('agent_id', 'unknown'),
    d.get('cwd', 'unknown')
)" 2>/dev/null || echo "unknown unknown unknown unknown unknown")"

# Map event name to readable action
ACTION="unknown"
case "$EVENT_NAME" in
    SubagentStart) ACTION="START" ;;
    SubagentStop)  ACTION="STOP"  ;;
    *)             ACTION="$EVENT_NAME" ;;
esac

# Read active issue ID if available
ISSUE_ID="none"
GATE_FILE="$HOME/.claude/gates/sentinel-issue-id"
if [ -f "$GATE_FILE" ]; then
    ISSUE_ID=$(cat "$GATE_FILE" 2>/dev/null | tr -d '[:space:]')
fi

# Timestamp
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Append to log file (create if missing)
mkdir -p "$(dirname "$LOG_FILE")"
echo "${TS} | AGENT ${ACTION} | type=${AGENT_TYPE} | session=${SESSION_ID} | agent_id=${AGENT_ID} | issue=${ISSUE_ID} | cwd=${CWD}" >> "$LOG_FILE"

# Phase 3.5 (OPS-347): Cleanup scoped Vault token files on SubagentStop.
# Token files are written by scripts/agent-vault-auth.sh as:
#   ~/.claude/cache/agent-vault-token-${SESSION_ID}-${role}
# Remove all role-token files for this session to limit token lifespan
# beyond Vault's own TTL cleanup. Failures are logged but never fatal.
if [[ "$ACTION" == "STOP" && "$SESSION_ID" != "unknown" ]]; then
    CACHE_DIR="$HOME/.claude/cache"
    # Use glob — safe because SESSION_ID is extracted from trusted hook JSON
    for TOKEN_FILE in "${CACHE_DIR}/agent-vault-token-${SESSION_ID}-"*; do
        if [[ -f "$TOKEN_FILE" ]]; then
            if rm -f "$TOKEN_FILE" 2>/dev/null; then
                echo "${TS} | TOKEN CLEANUP | removed ${TOKEN_FILE}" >> "$LOG_FILE"
            else
                echo "${TS} | TOKEN CLEANUP | WARNING: failed to remove ${TOKEN_FILE}" >> "$LOG_FILE"
            fi
        fi
    done
fi

# Return continue:true — never block agent operations
echo '{"continue":true}'
exit 0
