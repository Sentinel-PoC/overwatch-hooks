#!/usr/bin/env bash
# langfuse-prompt-hook.sh — UserPromptSubmit hook
# Captures user prompts and sends them as the trace input.
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
prompt = d.get('prompt', '')
trace_id = f'session-{session_id}'

if not prompt:
    sys.exit(0)

# Truncate prompt to 20KB
if len(prompt) > 20480:
    prompt = prompt[:20480] + '\n[TRUNCATED]'

# Update the session trace with user input, and create a generation span for the prompt
batch = [
    {
        'id': f'evt-prompt-{session_id}-$(date +%s%N)',
        'type': 'trace-create',
        'timestamp': '${TS}',
        'body': {
            'id': trace_id,
            'name': 'claude-code-session',
            'sessionId': session_id,
            'input': prompt,
        }
    },
    {
        'id': f'gen-prompt-$(date +%s%N)',
        'type': 'generation-create',
        'timestamp': '${TS}',
        'body': {
            'traceId': trace_id,
            'name': 'user-prompt',
            'startTime': '${TS}',
            'endTime': '${TS}',
            'input': prompt,
            'metadata': {
                'event': 'UserPromptSubmit',
            },
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
