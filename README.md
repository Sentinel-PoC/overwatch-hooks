# overwatch-hooks

Sanitized Claude Code hooks + install flow from the **Overwatch** multi-agent operator framework
(see [overwatch-framework](https://github.com/Sentinel-PoC/overwatch-framework)). Built by **Haists Consulting**.

These are the guardrail + telemetry hooks that make autonomous agents safe and observable:

| Hook | Purpose |
|------|---------|
| `hooks/enforce-plan-before-work.sh` | Require a plan/issue before mutating work |
| `hooks/guard-destructive-ops.sh` | Block dangerous operations |
| `hooks/require-issue-gate.sh` | Enforce a tracking issue per change |
| `hooks/validate-task-completion.sh` | Verify completion claims |
| `hooks/langfuse-*.sh`, `log-agent-lifecycle.sh` | OTEL/Langfuse telemetry |
| `hooks/notify-*.sh` | Session-end / pre-compact notifications |

## Install
```bash
./scripts/install.sh   # deploys hooks + settings.json into ~/.claude/
```

## Secrets
No credentials live in this repo. Secrets (Langfuse keys, etc.) are pulled from a secrets manager at runtime —
see the `__VAULT_*__` placeholders in `settings.json` and `scripts/agent-vault-auth.sh`. Replace
`127.0.0.1` / `example.com` / `secret/<path>` placeholders with your own infrastructure.
