#!/usr/bin/env python3
"""verify-otel-context.py — emit a synthetic OTLP span and confirm Langfuse stored its resource attrs.

Reads OTEL_RESOURCE_ATTRIBUTES + OTEL_EXPORTER_OTLP_ENDPOINT + OTEL_EXPORTER_OTLP_HEADERS
from env, sends one OTLP/HTTP/JSON trace, then queries Langfuse and asserts the
span landed with the expected plane.issue_id resource attribute.

Spends zero Claude tokens; uses the same OTLP endpoint that claude-code uses,
so a PASS here proves the audit-correlation path will work for real sessions.

Usage:
    source scripts/set-otel-context.sh OPS-189 operator
    python3 scripts/verify-otel-context.py

Exit codes:
    0  span emitted and observed in Langfuse with matching plane.issue_id
    1  span emitted but not observed within timeout
    2  configuration error (missing env vars)
    3  HTTP/network error
"""
from __future__ import annotations

import json
import os
import secrets
import sys
import time
import urllib.error
import urllib.request


def parse_kv(raw: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for kv in raw.split(","):
        kv = kv.strip()
        if not kv or "=" not in kv:
            continue
        k, v = kv.split("=", 1)
        out[k.strip()] = v.strip()
    return out


def fail(msg: str, code: int = 2) -> None:
    print(f"verify-otel-context: {msg}", file=sys.stderr)
    sys.exit(code)


def main() -> None:
    raw_attrs = os.environ.get("OTEL_RESOURCE_ATTRIBUTES", "")
    if not raw_attrs:
        fail("OTEL_RESOURCE_ATTRIBUTES not set. Source scripts/set-otel-context.sh first.")
    attrs = parse_kv(raw_attrs)

    plane_issue = attrs.get("plane.issue_id")
    if not plane_issue:
        fail(f"plane.issue_id missing from OTEL_RESOURCE_ATTRIBUTES (got keys: {list(attrs)})")

    endpoint = os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT", "").rstrip("/")
    if not endpoint:
        fail("OTEL_EXPORTER_OTLP_ENDPOINT not set.")

    headers = parse_kv(os.environ.get("OTEL_EXPORTER_OTLP_HEADERS", ""))
    if "Authorization" not in headers:
        fail("OTEL_EXPORTER_OTLP_HEADERS missing Authorization=Basic ... header.")

    trace_id = secrets.token_hex(16)
    span_id = secrets.token_hex(8)
    now_ns = time.time_ns()
    span_name = f"verify-otel-context-{plane_issue}-{int(time.time())}"

    resource_attrs = [{"key": k, "value": {"stringValue": v}} for k, v in attrs.items()]
    resource_attrs.append({"key": "service.name", "value": {"stringValue": "verify-otel-context"}})

    payload = {
        "resourceSpans": [
            {
                "resource": {"attributes": resource_attrs},
                "scopeSpans": [
                    {
                        "scope": {"name": "verify-otel-context", "version": "1"},
                        "spans": [
                            {
                                "traceId": trace_id,
                                "spanId": span_id,
                                "name": span_name,
                                "kind": 1,
                                "startTimeUnixNano": str(now_ns),
                                "endTimeUnixNano": str(now_ns + 1_000_000),
                                "attributes": [
                                    {"key": "verify.run", "value": {"stringValue": span_name}},
                                ],
                            }
                        ],
                    }
                ],
            }
        ]
    }

    url = f"{endpoint}/v1/traces"
    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        url,
        data=data,
        headers={**headers, "Content-Type": "application/json"},
    )
    print(f"POST {url}")
    print(f"  resource attrs: {raw_attrs}")
    print(f"  span name: {span_name}")
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:  # nosec B310 — operator-supplied internal langfuse OTEL endpoint
            print(f"  status: {resp.status}")
            print(f"  body: {resp.read().decode()[:300]}")
    except urllib.error.HTTPError as e:
        print(f"  HTTP error {e.code}: {e.read().decode()[:300]}", file=sys.stderr)
        sys.exit(3)
    except urllib.error.URLError as e:
        print(f"  URL error: {e.reason}", file=sys.stderr)
        sys.exit(3)

    base = endpoint.rsplit("/api/public/otel", 1)[0]
    from_ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 60))
    query_url = f"{base}/api/public/traces?fromTimestamp={from_ts}&limit=100"

    print()
    print(f"Polling {query_url} for span...")
    deadline = time.time() + 30
    while time.time() < deadline:
        time.sleep(3)
        q_req = urllib.request.Request(query_url, headers={"Authorization": headers["Authorization"]})
        try:
            with urllib.request.urlopen(q_req, timeout=10) as resp:  # nosec B310 — derived from operator-supplied internal langfuse base URL
                body = json.loads(resp.read())
        except urllib.error.HTTPError as e:
            print(f"  query HTTP error {e.code}", file=sys.stderr)
            sys.exit(3)

        for trace in body.get("data", []):
            if trace.get("name") == span_name:
                meta = trace.get("metadata") or {}
                rattrs = meta.get("resourceAttributes") or {}
                got = rattrs.get("plane.issue_id")
                print(f"FOUND trace id={trace.get('id')}")
                print(f"  metadata.resourceAttributes.plane.issue_id = {got!r}")
                if got == plane_issue:
                    print(f"PASS — Langfuse stored plane.issue_id={plane_issue} on the test span.")
                    sys.exit(0)
                else:
                    print(f"FAIL — expected plane.issue_id={plane_issue!r}, got {got!r}", file=sys.stderr)
                    sys.exit(1)
        print("  not yet visible, retrying...")

    print(f"FAIL — span '{span_name}' did not appear in Langfuse within 30s.", file=sys.stderr)
    sys.exit(1)


if __name__ == "__main__":
    main()
