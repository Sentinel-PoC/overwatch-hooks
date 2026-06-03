#!/usr/bin/env bash
# guard-destructive-ops.sh — PreToolUse guardrail for autonomous / headless runs.
#
# Deterministically DENIES destructive shell commands and writes to protected
# files, so the nightly backlog-burner can run unattended without a human
# approving every tool call. Defense-in-depth alongside `--permission-mode auto`
# (the classifier is the backstop; this is the hard, explicit floor).
#
# Wire as a PreToolUse hook with matcher "Bash|Edit|Write|MultiEdit|NotebookEdit"
# (see automation/backlog-burn-settings.json). Native JSON permissionDecision
# protocol; always exits 0. Fails OPEN on unparseable input (logs to stderr) so a
# malformed event never wedges the run — auto-mode remains the backstop.
#
# Enforces CLAUDE.md §10 HARD LIMITS, §8a/§9 artifact ownership, and the
# "never silently do destructive infra ops" rule. NOT a substitute for the
# workflow's own collision rules — it is the last line.
set -uo pipefail
INPUT="$(cat)"
GUARD_INPUT="$INPUT" python3 - <<'PY'
import os, json, sys, re

raw = os.environ.get("GUARD_INPUT", "")

def emit(decision, reason=None):
    out = {"continue": True, "hookSpecificOutput": {
        "hookEventName": "PreToolUse", "permissionDecision": decision}}
    if reason:
        out["hookSpecificOutput"]["permissionDecisionReason"] = reason
    print(json.dumps(out)); sys.exit(0)

try:
    d = json.loads(raw)
except Exception as e:
    sys.stderr.write("guard-destructive-ops: unparseable input, allowing (auto-mode backstop): %s\n" % e)
    emit("allow")

tool = d.get("tool_name") or d.get("toolName") or ""
ti = d.get("tool_input") or d.get("toolInput") or {}

DESTRUCTIVE = [
    (r'\b(kubectl|oc)\s+delete\s+(pvc|persistentvolumeclaim|pv|persistentvolume|ns|namespace|node|crd|sts|statefulset)\b',
     "deletes a PVC/PV/namespace/node/CRD/StatefulSet — destructive, operator only"),
    (r'\bpct\s+destroy\b|\bqm\s+(destroy|stop)\b', "destroys/stops a Proxmox CT/VM — operator only"),
    (r'\bzfs\s+destroy\b|\bdataset\b.*\bdestroy\b', "destroys a ZFS dataset — operator only"),
    (r'\bvault\s+(kv\s+)?(delete|destroy)\b|\bvault\s+kv\s+metadata\s+delete\b', "deletes a Vault secret — operator only"),
    (r'\bmc\s+(rb|rm)\b.*(--recursive|--force|\s-r\b)', "recursive MinIO bucket/object removal — operator only"),
    (r'\brm\s+-[a-z]*r[a-z]*f|\brm\s+-[a-z]*f[a-z]*r', "rm -rf — restrict to /tmp paths and run manually"),
    (r'\b(mkfs|wipefs)\b|\bdd\b.*\bof=/dev/', "disk wipe — operator only"),
    (r'\bgit\s+push\b.*(--force|-f)\b.*\b(main|master)\b|\bgit\s+push\b.*\b(main|master)\b.*(--force|-f)\b',
     "force-push to main/master — operator only"),
    (r'\bsystemctl\s+(stop|disable|mask)\b.*\b(wazuh|crowdsec|falco|kyverno|gitleaks|trivy)\b',
     "stopping/disabling security tooling violates CLAUDE.md §10 HARD LIMITS"),
    (r'\b(shutdown|reboot|halt|poweroff)\b', "host power-state change — operator only"),
    (r'force_merge', "Forgejo force_merge bypasses branch protection — judge/operator decision, not autonomous"),
]

PROTECTED = [
    (r'(^|/)CLAUDE\.md$', "CLAUDE.md requires explicit operator authorization (§10)"),
    (r'image-manifest\.txt$', "supply-chain file owned by backlog-burn-036 / operator"),
    (r'trust-policy\.yaml$', "supply-chain trust policy — operator only"),
    (r'check-strength\.yaml$', "READ-ONLY for all agents always (§9)"),
    (r'nist-compliance-check\.sh$', "READ-ONLY for all agents always (§9)"),
    (r'(system-security-plan|security-assessment-report|gap-analysis)', "compliance artifact — COMPLIANCE-SCRIBE only (§9)"),
    (r'(^|/)(SSP|SAR|POAM)\b', "compliance artifact — COMPLIANCE-SCRIBE only (§9)"),
    (r'(current-state|score-history)\.md$', "written only by the reconciliation agent (§9)"),
]

if tool == "Bash":
    cmd = ti.get("command", "") or ""
    for pat, msg in DESTRUCTIVE:
        if re.search(pat, cmd, re.I):
            emit("deny", "Blocked by guard-destructive-ops: " + msg + ". If genuinely required, the operator runs it manually.")
    emit("allow")
elif tool in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
    fp = ti.get("file_path") or ti.get("notebook_path") or ""
    for pat, msg in PROTECTED:
        if re.search(pat, fp, re.I):
            emit("deny", "Blocked by guard-destructive-ops: " + msg)
    emit("allow")
else:
    emit("allow")
PY
