#!/usr/bin/env bash
# notify-precompact.sh — PreCompact hook
# Saves session state and notifies on Telegram before context compaction.
# Returns {"continue":true} — never blocks compaction.

set -euo pipefail

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id','unknown'))" 2>/dev/null || echo "unknown")
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Save compaction event to log
LOG_DIR="${HOME}/.claude/logs"
mkdir -p "$LOG_DIR"
echo "${TS} | PRECOMPACT | session=${SESSION_ID}" >> "${LOG_DIR}/compaction.log"

# Notify Telegram (best-effort)
TELEGRAM_STATE_DIR="${HOME}/.claude/channels/telegram"
BOT_TOKEN=""
CHAT_ID=""
if [ -f "${TELEGRAM_STATE_DIR}/.env" ]; then
    BOT_TOKEN=$(grep '^TELEGRAM_BOT_TOKEN=' "${TELEGRAM_STATE_DIR}/.env" | cut -d= -f2-)
fi
if [ -f "${TELEGRAM_STATE_DIR}/access.json" ]; then
    CHAT_ID=$(python3 -c "
import json
with open('${TELEGRAM_STATE_DIR}/access.json') as f:
    d = json.load(f)
pairs = d.get('pairs', {})
for k,v in pairs.items():
    if v.get('approved'):
        print(v.get('chatId', k))
        break
" 2>/dev/null || true)
fi

if [ -n "$BOT_TOKEN" ] && [ -n "$CHAT_ID" ]; then
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d "chat_id=${CHAT_ID}" \
        -d "text=⚡ *Context compaction starting*
Session: \`${SESSION_ID}\`
Time: ${TS}
Context will be summarized and older messages cleared." \
        -d "parse_mode=Markdown" > /dev/null 2>&1 || true
fi

echo '{"continue":true}'
exit 0
