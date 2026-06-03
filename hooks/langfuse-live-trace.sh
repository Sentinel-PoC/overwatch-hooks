#!/usr/bin/env bash
# langfuse-live-trace.sh — PostToolUse hook
# Sends each tool call as a Langfuse span with full input/output under the session trace.
set -euo pipefail

LANGFUSE_URL="https://your-host.example.com"

# Build auth from env (settings.json sets LANGFUSE_PUBLIC_KEY + LANGFUSE_SECRET_KEY).
# Fall back to LANGFUSE_AUTH if pre-encoded. If both empty, log + exit 0 (don't break hook chain).
if [ -n "${LANGFUSE_AUTH:-}" ]; then
    AUTH="${LANGFUSE_AUTH}"
elif [ -n "${LANGFUSE_PUBLIC_KEY:-}" ] && [ -n "${LANGFUSE_SECRET_KEY:-}" ]; then
    AUTH=$(printf '%s:%s' "${LANGFUSE_PUBLIC_KEY}" "${LANGFUSE_SECRET_KEY}" | base64 -w0)
else
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] langfuse hook: LANGFUSE_PUBLIC_KEY/SECRET_KEY not set; skipping" >&2
    exit 0
fi

INPUT=$(cat)
TS=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
SPAN_ID="span-$(date +%s%N)-${RANDOM}"

echo "$INPUT" | python3 -c "
import json, sys, os

d = json.load(sys.stdin)

session_id = d.get('session_id', 'unknown')
tool_name = d.get('tool_name', 'unknown')
tool_use_id = d.get('tool_use_id', '')
agent_type = d.get('agent_type', 'lead')
agent_id = d.get('agent_id', '')
cwd = d.get('cwd', '')

# Tool input — can be dict or string
tool_input = d.get('tool_input', {})
if isinstance(tool_input, str):
    try:
        tool_input = json.loads(tool_input)
    except:
        tool_input = {'raw': tool_input}

# Tool response — can be large, truncate to 20KB
tool_response = d.get('tool_response', '')
if isinstance(tool_response, dict):
    tool_response = json.dumps(tool_response, default=str)
elif not isinstance(tool_response, str):
    tool_response = str(tool_response)
if len(tool_response) > 20480:
    tool_response = tool_response[:20480] + '\n[TRUNCATED]'

trace_id = f'session-{session_id}'
ts = os.environ.get('TS', '${TS}')
span_id = os.environ.get('SPAN_ID', '${SPAN_ID}')

batch = [
    {
        'id': span_id,
        'type': 'span-create',
        'timestamp': ts,
        'body': {
            'id': span_id,
            'traceId': trace_id,
            'name': f'tool:{tool_name}',
            'startTime': ts,
            'input': tool_input,
            'metadata': {
                'tool_use_id': tool_use_id,
                'agent_type': agent_type,
                'agent_id': agent_id,
                'cwd': cwd,
                'event': 'PostToolUse',
            },
        }
    },
    {
        'id': span_id + '-end',
        'type': 'span-update',
        'timestamp': ts,
        'body': {
            'id': span_id,
            'traceId': trace_id,
            'endTime': ts,
            'output': tool_response if tool_response else None,
        }
    }
]

print(json.dumps({'batch': batch}))
" | curl -sk -X POST "${LANGFUSE_URL}/api/public/ingestion" \
  -H "Authorization: Basic ${AUTH}" \
  -H "Content-Type: application/json" \
  -d @- > /dev/null 2>&1

echo '{"continue":true}'
exit 0
