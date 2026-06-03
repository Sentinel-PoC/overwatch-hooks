#!/usr/bin/env bash
# langfuse-agent-hook.sh — SubagentStart/SubagentStop hook
# Tracks agent lifecycle as spans in Langfuse under the session trace.
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

python3 -c "
import json, sys

d = json.loads('''$(echo "$INPUT" | sed "s/'/\\\\'/g")''')

session_id = d.get('session_id', 'unknown')
event = d.get('hook_event_name', 'unknown')
agent_type = d.get('agent_type', 'unknown')
agent_id = d.get('agent_id', 'unknown')
trace_id = f'session-{session_id}'
span_id = f'agent-{agent_id}'

batch = []

if event == 'SubagentStart':
    batch.append({
        'id': f'evt-agent-start-{agent_id}',
        'type': 'span-create',
        'timestamp': '${TS}',
        'body': {
            'id': span_id,
            'traceId': trace_id,
            'name': f'subagent:{agent_type}',
            'startTime': '${TS}',
            'input': {'agent_id': agent_id, 'agent_type': agent_type},
            'metadata': {
                'event': 'SubagentStart',
                'agent_id': agent_id,
                'agent_type': agent_type,
            },
        }
    })
elif event == 'SubagentStop':
    last_msg = d.get('last_assistant_message', '')
    if len(last_msg) > 20480:
        last_msg = last_msg[:20480] + '\n[TRUNCATED]'
    transcript = d.get('agent_transcript_path', '')
    batch.append({
        'id': f'evt-agent-stop-{agent_id}',
        'type': 'span-update',
        'timestamp': '${TS}',
        'body': {
            'id': span_id,
            'traceId': trace_id,
            'endTime': '${TS}',
            'output': last_msg if last_msg else None,
            'metadata': {
                'event': 'SubagentStop',
                'agent_transcript_path': transcript,
                'stop_hook_active': d.get('stop_hook_active', False),
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
