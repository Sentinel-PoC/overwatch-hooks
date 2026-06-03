#!/usr/bin/env python3
"""langfuse-stop-hook.py — Stop hook

Instead of creating a duplicate generation (native OTEL already does turn-NNNN),
this hook:
1. Updates the session trace with the last assistant message as output
2. Reads the JSONL transcript to extract token usage for the full session
3. Sends a trace-level summary with cumulative stats
"""

import base64
import glob
import json
import os
import sys
import time
import urllib.request
import ssl

LANGFUSE_URL = "https://your-host.example.com"

# Build auth from env (settings.json sets LANGFUSE_PUBLIC_KEY + LANGFUSE_SECRET_KEY).
# Fall back to LANGFUSE_AUTH if pre-encoded. If both empty, skip gracefully.
LANGFUSE_AUTH = os.environ.get("LANGFUSE_AUTH")
if not LANGFUSE_AUTH:
    pk = os.environ.get("LANGFUSE_PUBLIC_KEY", "")
    sk = os.environ.get("LANGFUSE_SECRET_KEY", "")
    if pk and sk:
        LANGFUSE_AUTH = base64.b64encode(f"{pk}:{sk}".encode()).decode()
    else:
        print("[langfuse]: LANGFUSE_PUBLIC_KEY/SECRET_KEY not set; skipping", file=sys.stderr)
        sys.exit(0)
AUTH = LANGFUSE_AUTH

# Skip SSL verification for internal endpoint
CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE


def send_batch(batch):
    payload = json.dumps({"batch": batch}).encode("utf-8")
    req = urllib.request.Request(
        f"{LANGFUSE_URL}/api/public/ingestion",
        data=payload,
        headers={
            "Authorization": f"Basic {AUTH}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        urllib.request.urlopen(req, timeout=10, context=CTX)  # nosec B310 — fixed internal langfuse URL
    except Exception:
        pass


def read_transcript_stats(transcript_path, session_id):
    """Read JSONL transcript to get session-level stats."""
    # Try transcript_path first, then guess from session_id
    paths_to_try = []
    if transcript_path:
        paths_to_try.append(transcript_path)
    paths_to_try.append(
        os.path.expanduser(f"~/.claude/projects/-home-koiakoia/{session_id}.jsonl")
    )

    stats = {
        "user_messages": 0,
        "assistant_messages": 0,
        "tool_calls": 0,
        "tools_used": {},
        "first_timestamp": None,
        "last_timestamp": None,
        # OPS-330: pull token usage from Anthropic API responses recorded on each
        # assistant turn. Native OTEL export drops these (OPS-328); the JSONL is
        # the only on-host source until OPS-328 ships an attribute remap.
        "input_tokens": 0,
        "output_tokens": 0,
        "cache_read_input_tokens": 0,
        "cache_creation_input_tokens": 0,
        "models_seen": {},
    }

    for path in paths_to_try:
        if not os.path.exists(path):
            continue
        try:
            with open(path) as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        r = json.loads(line)
                    except json.JSONDecodeError:
                        continue

                    ts = r.get("timestamp")
                    if ts:
                        if not stats["first_timestamp"]:
                            stats["first_timestamp"] = ts
                        stats["last_timestamp"] = ts

                    msg_type = r.get("type", "")
                    msg = r.get("message", {})
                    role = msg.get("role", "")
                    content = msg.get("content", "")

                    if msg_type == "user" and isinstance(content, str) and content.strip():
                        stats["user_messages"] += 1
                    elif role == "assistant" and isinstance(content, list):
                        stats["assistant_messages"] += 1
                        for block in content:
                            if isinstance(block, dict) and block.get("type") == "tool_use":
                                tool_name = block.get("name", "unknown")
                                stats["tool_calls"] += 1
                                stats["tools_used"][tool_name] = (
                                    stats["tools_used"].get(tool_name, 0) + 1
                                )
                        # OPS-330: extract Anthropic API usage block. Field names
                        # are stable across model families; missing keys default
                        # to 0 (e.g. cache_* are absent on non-cached calls).
                        usage = msg.get("usage") or {}
                        stats["input_tokens"] += usage.get("input_tokens", 0) or 0
                        stats["output_tokens"] += usage.get("output_tokens", 0) or 0
                        stats["cache_read_input_tokens"] += (
                            usage.get("cache_read_input_tokens", 0) or 0
                        )
                        stats["cache_creation_input_tokens"] += (
                            usage.get("cache_creation_input_tokens", 0) or 0
                        )
                        model = msg.get("model")
                        if model:
                            stats["models_seen"][model] = (
                                stats["models_seen"].get(model, 0) + 1
                            )
            break  # Found a valid file
        except Exception:
            continue

    return stats


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        print('{"continue":true}')
        return

    session_id = data.get("session_id", "unknown")
    last_msg = data.get("last_assistant_message", "")
    transcript_path = data.get("transcript_path", "")

    trace_id = f"session-{session_id}"
    ts = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime())

    # Truncate output to 30KB
    output = last_msg[:30720] if last_msg else ""

    # Get session stats from JSONL
    stats = read_transcript_stats(transcript_path, session_id)

    # Calculate duration from transcript timestamps
    duration_sec = 0
    if stats["first_timestamp"] and stats["last_timestamp"]:
        try:
            from datetime import datetime
            fmt = "%Y-%m-%dT%H:%M:%S"
            first = stats["first_timestamp"][:19]
            last = stats["last_timestamp"][:19]
            t1 = datetime.fromisoformat(first)
            t2 = datetime.fromisoformat(last)
            duration_sec = (t2 - t1).total_seconds()
        except Exception:
            pass

    batch = [
        {
            "id": f"evt-stop-{session_id}-{int(time.time())}",
            "type": "trace-create",
            "timestamp": ts,
            "body": {
                "id": trace_id,
                "name": "claude-code-session",
                "sessionId": session_id,
                "output": output if output else None,
                "metadata": {
                    "event": "Stop",
                    "finalized_at": ts,
                    "session_stats": {
                        "user_messages": stats["user_messages"],
                        "assistant_messages": stats["assistant_messages"],
                        "tool_calls": stats["tool_calls"],
                        "top_tools": dict(
                            sorted(
                                stats["tools_used"].items(),
                                key=lambda x: x[1],
                                reverse=True,
                            )[:10]
                        ),
                        "duration_seconds": duration_sec,
                        "duration_human": (
                            f"{int(duration_sec // 60)}m {int(duration_sec % 60)}s"
                            if duration_sec
                            else "unknown"
                        ),
                        # OPS-330: token usage rolled up from the JSONL transcript.
                        # The four buckets are kept atomic because each is billed
                        # at a different rate (input full, cache_creation ~1.25x,
                        # cache_read ~0.10x of input). Don't sum them here — the
                        # cost calculation belongs in whatever consumes this.
                        "tokens": {
                            "input": stats["input_tokens"],
                            "output": stats["output_tokens"],
                            "cache_read": stats["cache_read_input_tokens"],
                            "cache_creation": stats["cache_creation_input_tokens"],
                        },
                        "models_seen": stats["models_seen"],
                    },
                },
            },
        }
    ]

    send_batch(batch)
    print('{"continue":true}')


if __name__ == "__main__":
    main()
