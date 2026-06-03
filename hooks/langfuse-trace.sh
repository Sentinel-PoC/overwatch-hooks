#!/usr/bin/env bash
# langfuse-trace.sh — SessionStart / Stop hook
# Creates a parent Langfuse trace for the session with full metadata.
# Stop event updates trace with output summary.
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

echo "$INPUT" | python3 -c "
import json, sys, os

d = json.load(sys.stdin)
session_id = d.get('session_id', 'unknown')
hook_event = d.get('hook_event_name', 'unknown')
trace_id = f'session-{session_id}'
ts = os.environ.get('TS', '')

batch = []

if hook_event == 'SessionStart':
    meta = {
        'source': d.get('source', 'unknown'),
        'agent_type': d.get('agent_type', 'lead'),
        'model': d.get('model', 'unknown'),
        'cwd': d.get('cwd', 'unknown'),
        'permission_mode': d.get('permission_mode', 'unknown'),
        'transcript_path': d.get('transcript_path', ''),
        'event': 'SessionStart',
    }
    batch.append({
        'id': f'evt-session-start-{session_id}',
        'type': 'trace-create',
        'timestamp': ts,
        'body': {
            'id': trace_id,
            'name': 'claude-code-session',
            'sessionId': session_id,
            'metadata': meta,
            'tags': ['session', meta.get('agent_type', 'lead'), meta.get('source', 'startup')],
        }
    })

elif hook_event == 'Stop':
    last_msg = d.get('last_assistant_message', '')
    if len(last_msg) > 10240:
        last_msg = last_msg[:10240] + '\n[TRUNCATED]'
    batch.append({
        'id': f'evt-stop-{session_id}-{ts}',
        'type': 'trace-create',
        'timestamp': ts,
        'body': {
            'id': trace_id,
            'name': 'claude-code-session',
            'sessionId': session_id,
            'output': last_msg if last_msg.strip() else None,
            'metadata': {
                'event': 'Stop',
                'finalized_at': ts,
            },
        }
    })

if batch:
    print(json.dumps({'batch': batch}))
else:
    sys.exit(1)
" | curl -sk -X POST "${LANGFUSE_URL}/api/public/ingestion" \
  -H "Authorization: Basic ${AUTH}" \
  -H "Content-Type: application/json" \
  -d @- > /dev/null 2>&1

echo '{"continue":true}'
exit 0
