#!/usr/bin/env bash
# install.sh — Deploy claude-config to the workstation.
# Symlinks hooks, settings, and systemd units from this repo into their
# expected locations. The repo is the source of truth.
#
# Usage: ./scripts/install.sh [--restart]
#   --restart  Also restart the claude-channels service after install

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLAUDE_DIR="${HOME}/.claude"
HOOKS_DIR="${CLAUDE_DIR}/hooks"
SYSTEMD_DIR="${HOME}/.config/systemd/user"
LOGS_DIR="${CLAUDE_DIR}/logs"

echo "=== claude-config install ==="
echo "Repo: ${REPO_DIR}"
echo ""

# Ensure target directories exist
mkdir -p "$HOOKS_DIR" "$SYSTEMD_DIR" "$LOGS_DIR"

# --- Settings (Vault-rendered — NOT symlinked) ---
# settings.json in the repo is a TEMPLATE with __VAULT_LANGFUSE_*__ placeholders.
# Credentials are fetched from Vault at install time and written to ~/.claude/settings.json.
# ~/.claude/settings.json is never committed to git.
echo "-> settings.json (Vault render)"
if [ -n "${VAULT_ADDR:-}" ]; then
    VAULT_BIN="${HOME}/.local/bin/vault"
    if ! command -v vault &>/dev/null && [ -x "${VAULT_BIN}" ]; then
        export PATH="${HOME}/.local/bin:${PATH}"
    fi

    # Fetch Langfuse credentials from Vault
    LF_PUB=$(vault kv get -field=public_key secret/langfuse/overwatch-agents 2>/dev/null)
    LF_SEC=$(vault kv get -field=secret_key secret/langfuse/overwatch-agents 2>/dev/null)

    if [ -n "${LF_PUB}" ] && [ -n "${LF_SEC}" ]; then
        # Compute OTLP Basic auth header (base64 of pub:sec, no trailing newline)
        OTLP_AUTH=$(printf '%s:%s' "${LF_PUB}" "${LF_SEC}" | base64 -w 0)

        # Remove stale symlink if present (legacy: settings.json was previously symlinked)
        if [ -L "${CLAUDE_DIR}/settings.json" ]; then
            rm "${CLAUDE_DIR}/settings.json"
            echo "   removed legacy symlink"
        fi

        # Render template to ~/.claude/settings.json (mode 0600)
        # Render directly to tmp file — avoids large-variable issues in bash
        SETTINGS_TMP="${CLAUDE_DIR}/settings.json.tmp.$$"
        sed \
            -e "s|__VAULT_LANGFUSE_PUBLIC_KEY__|${LF_PUB}|g" \
            -e "s|__VAULT_LANGFUSE_SECRET_KEY__|${LF_SEC}|g" \
            -e "s|__VAULT_LANGFUSE_OTLP_AUTH__|${OTLP_AUTH}|g" \
            "${REPO_DIR}/settings.json" > "${SETTINGS_TMP}"
        chmod 0600 "${SETTINGS_TMP}"

        # Atomic rename only if content changed (idempotent)
        RENDERED_HASH=$(sha256sum "${SETTINGS_TMP}" | awk '{print $1}')
        # Suppress pipefail for missing-file case (|| true prevents set -e exit)
        EXISTING_HASH=$(sha256sum "${CLAUDE_DIR}/settings.json" 2>/dev/null | awk '{print $1}' || true)

        if [ "${RENDERED_HASH}" != "${EXISTING_HASH}" ]; then
            mv "${SETTINGS_TMP}" "${CLAUDE_DIR}/settings.json"
            echo "   rendered from Vault (updated)"
        else
            rm -f "${SETTINGS_TMP}"
            echo "   rendered from Vault (no change)"
        fi
    else
        echo "   WARNING: Vault returned empty Langfuse credentials — settings.json NOT updated"
        echo "   Re-run: VAULT_ADDR=... ./scripts/install.sh"
        # If no settings.json exists yet, leave placeholder template as fallback (will fail telemetry but not block Claude)
        if [ ! -f "${CLAUDE_DIR}/settings.json" ] && [ ! -L "${CLAUDE_DIR}/settings.json" ]; then
            ln -sf "${REPO_DIR}/settings.json" "${CLAUDE_DIR}/settings.json"
            echo "   symlinked template as fallback (telemetry will fail until Vault is reachable)"
        fi
    fi
else
    echo "   [skip] VAULT_ADDR not set — settings.json not rendered"
    echo "   Set VAULT_ADDR and re-run, or manually render:"
    echo "     VAULT_ADDR=https://127.0.0.1:8200 ./scripts/install.sh"
    # Fallback: symlink template if nothing exists yet
    if [ ! -f "${CLAUDE_DIR}/settings.json" ] && [ ! -L "${CLAUDE_DIR}/settings.json" ]; then
        ln -sf "${REPO_DIR}/settings.json" "${CLAUDE_DIR}/settings.json"
        echo "   symlinked template as fallback (telemetry will fail until credentials are rendered)"
    fi
fi

# --- Hooks ---
echo "-> hooks/"
for hook in "${REPO_DIR}"/hooks/*.sh "${REPO_DIR}"/hooks/*.py; do
    [ -f "$hook" ] || continue
    name=$(basename "$hook")
    chmod +x "$hook"
    ln -sf "$hook" "${HOOKS_DIR}/${name}"
    echo "   ${name}"
done

# --- Reusable workflow scripts (Claude Code Workflow tool) ---
echo "-> workflows/"
mkdir -p "${CLAUDE_DIR}/workflows"
for wf in "${REPO_DIR}"/workflows/*.js; do
    [ -f "$wf" ] || continue
    name=$(basename "$wf")
    ln -sf "$wf" "${CLAUDE_DIR}/workflows/${name}"
    echo "   ${name}"
done

# --- Automation: backlog-burn settings profile + headless wrapper ---
# The systemd unit ExecStart references ~/.claude/scripts/run-backlog-burn.sh, and the
# wrapper reads ~/.claude/automation/backlog-burn-settings.json + ~/.claude/workflows/*.js.
echo "-> automation/ + scripts/"
mkdir -p "${CLAUDE_DIR}/automation" "${CLAUDE_DIR}/scripts" "${CLAUDE_DIR}/automation/logs"
if [ -f "${REPO_DIR}/scripts/run-backlog-burn.sh" ]; then
    chmod +x "${REPO_DIR}/scripts/run-backlog-burn.sh"
    ln -sf "${REPO_DIR}/scripts/run-backlog-burn.sh" "${CLAUDE_DIR}/scripts/run-backlog-burn.sh"
    echo "   scripts/run-backlog-burn.sh"
fi
if [ -f "${REPO_DIR}/automation/backlog-burn-settings.json" ]; then
    ln -sf "${REPO_DIR}/automation/backlog-burn-settings.json" "${CLAUDE_DIR}/automation/backlog-burn-settings.json"
    echo "   automation/backlog-burn-settings.json"
fi
# NOTE: claude-backlog-burn.timer is symlinked by the systemd block below but is NOT
# auto-enabled (ships disabled, BURN_DRY_RUN=1). Enable per automation/README.md rollout.

# --- MCP servers (deployed to ~/.local/bin, registered in ~/.claude.json) ---
# MCP server scripts live in mcp/ in this repo; wrappers are deployed as executables.
# The Python MCP server reuses the netbox venv (~/.local/venv-netbox-mcp) which already
# has mcp==1.27.0 + httpx + requests. No new venv is needed.
echo "-> mcp/"
LOCAL_BIN="${HOME}/.local/bin"
mkdir -p "$LOCAL_BIN"
for mcp_file in "${REPO_DIR}"/mcp/*; do
    [ -f "$mcp_file" ] || continue
    name=$(basename "$mcp_file")
    chmod +x "$mcp_file"
    ln -sf "$mcp_file" "${LOCAL_BIN}/${name}"
    echo "   ${name} -> ${LOCAL_BIN}/${name}"
done

# Register argocd, backstage, and plane MCP servers in ~/.claude.json if not already present.
# Reads the existing file, adds any missing entries, writes atomically.
CLAUDE_JSON="${HOME}/.claude.json"
if [ -f "$CLAUDE_JSON" ] && command -v python3 &>/dev/null; then
    python3 - "${LOCAL_BIN}/argocd-mcp-wrapper" "${LOCAL_BIN}/backstage-mcp-wrapper" "${LOCAL_BIN}/plane-mcp-wrapper" "${CLAUDE_JSON}" <<'EOF'
import sys, json
argocd_path, backstage_path, plane_path, claude_json_path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(claude_json_path) as f:
    config = json.load(f)
mcp_servers = config.setdefault("mcpServers", {})
changed = False
if "argocd" not in mcp_servers:
    mcp_servers["argocd"] = {"command": argocd_path}
    changed = True
    print("   argocd MCP server registered in ~/.claude.json")
else:
    print("   argocd MCP server already registered (no change)")
if "backstage" not in mcp_servers:
    mcp_servers["backstage"] = {"command": backstage_path}
    changed = True
    print("   backstage MCP server registered in ~/.claude.json")
else:
    print("   backstage MCP server already registered (no change)")
if "plane" not in mcp_servers:
    mcp_servers["plane"] = {"command": plane_path}
    changed = True
    print("   plane MCP server registered in ~/.claude.json")
else:
    print("   plane MCP server already registered (no change)")
if changed:
    with open(claude_json_path, "w") as f:
        json.dump(config, f, indent=2)
        f.write("\n")
EOF
else
    echo "   [skip] ~/.claude.json registration — file not found or python3 unavailable"
    echo "   Add manually: {\"mcpServers\": {\"argocd\": {\"command\": \"${LOCAL_BIN}/argocd-mcp-wrapper\"}, \"backstage\": {\"command\": \"${LOCAL_BIN}/backstage-mcp-wrapper\"}, \"plane\": {\"command\": \"${LOCAL_BIN}/plane-mcp-wrapper\"}}}"
fi

# --- Channel wrapper ---
echo "-> channels/"
chmod +x "${REPO_DIR}/channels/run-channels.sh"
echo "   run-channels.sh (executable)"
chmod +x "${REPO_DIR}/channels/install-channels.sh"
echo "   install-channels.sh (executable)"

# --- systemd units ---
echo "-> systemd/"
for unit in "${REPO_DIR}"/systemd/*.service "${REPO_DIR}"/systemd/*.timer; do
    [ -f "$unit" ] || continue
    name=$(basename "$unit")
    ln -sf "$unit" "${SYSTEMD_DIR}/${name}"
    echo "   ${name}"
done

# Reload systemd
systemctl --user daemon-reload
echo "   daemon-reload done"

# Enable the channels service
systemctl --user enable claude-channels.service 2>/dev/null || true
echo "   claude-channels.service enabled"

# --- Optional restart ---
if [[ "${1:-}" == "--restart" ]]; then
    echo ""
    echo "=== Restarting claude-channels ==="
    systemctl --user stop claude-channels.service 2>/dev/null || true
    # Kill any leftover tmux session from old service
    tmux kill-session -t claude-channels 2>/dev/null || true
    # Kill any orphan claude processes from old channels session
    pkill -f 'claude.*--channels' 2>/dev/null || true
    sleep 2
    systemctl --user start claude-channels.service
    echo "   started"
    sleep 3
    systemctl --user status claude-channels.service --no-pager || true
fi

# --- otelcol config (OPS-620) ---
# otelcol/config.yaml is a template; the Langfuse Basic auth header is rendered from Vault
# at install time (same pattern as settings.json). Deployed to ~/.local/etc/otelcol/config.yaml.
echo "-> otelcol/config.yaml (Vault render)"
OTELCOL_CFG_DIR="${HOME}/.local/etc/otelcol"
mkdir -p "${OTELCOL_CFG_DIR}"
if [ -n "${VAULT_ADDR:-}" ]; then
    VAULT_BIN="${HOME}/.local/bin/vault"
    if ! command -v vault &>/dev/null && [ -x "${VAULT_BIN}" ]; then
        export PATH="${HOME}/.local/bin:${PATH}"
    fi

    # Reuse already-fetched Langfuse creds if available, otherwise re-fetch.
    # (LF_PUB / LF_SEC are set by the settings.json block above if Vault was reachable.)
    if [ -z "${LF_PUB:-}" ] || [ -z "${LF_SEC:-}" ]; then
        LF_PUB=$(vault kv get -field=public_key secret/langfuse/overwatch-agents 2>/dev/null)
        LF_SEC=$(vault kv get -field=secret_key secret/langfuse/overwatch-agents 2>/dev/null)
    fi

    if [ -n "${LF_PUB}" ] && [ -n "${LF_SEC}" ]; then
        OTLP_AUTH=$(printf '%s:%s' "${LF_PUB}" "${LF_SEC}" | base64 -w 0)
        OTELCOL_TMP="${OTELCOL_CFG_DIR}/config.yaml.tmp.$$"
        sed -e "s|__VAULT_LANGFUSE_OTLP_AUTH__|${OTLP_AUTH}|g" \
            "${REPO_DIR}/otelcol/config.yaml" > "${OTELCOL_TMP}"
        chmod 0600 "${OTELCOL_TMP}"

        RENDERED_HASH=$(sha256sum "${OTELCOL_TMP}" | awk '{print $1}')
        EXISTING_HASH=$(sha256sum "${OTELCOL_CFG_DIR}/config.yaml" 2>/dev/null | awk '{print $1}' || true)

        if [ "${RENDERED_HASH}" != "${EXISTING_HASH}" ]; then
            mv "${OTELCOL_TMP}" "${OTELCOL_CFG_DIR}/config.yaml"
            echo "   rendered from Vault (updated)"
            # Restart otelcol if running so the new config takes effect
            systemctl --user restart otelcol.service 2>/dev/null && echo "   otelcol.service restarted" || true
        else
            rm -f "${OTELCOL_TMP}"
            echo "   rendered from Vault (no change)"
        fi
    else
        echo "   WARNING: Vault returned empty Langfuse credentials — otelcol/config.yaml NOT updated"
        echo "   Re-run: VAULT_ADDR=... ./scripts/install.sh"
    fi
else
    echo "   [skip] VAULT_ADDR not set — otelcol/config.yaml not rendered"
    echo "   Set VAULT_ADDR and re-run, or manually render:"
    echo "     VAULT_ADDR=https://your-host.example.com ./scripts/install.sh"
fi

# --- Channels secrets bootstrap ---
echo "-> channels secrets"
if [ -n "${VAULT_ADDR:-}" ] && [ -f "${HOME}/.vault-token" ]; then
    echo "   VAULT_ADDR set + ~/.vault-token found — running channels/install-channels.sh"
    "${REPO_DIR}/channels/install-channels.sh" || {
        echo "   WARNING: install-channels.sh failed — check Vault connectivity"
        echo "   Re-run manually: ${REPO_DIR}/channels/install-channels.sh"
    }
else
    echo "   [skip] channels bootstrap — set VAULT_ADDR + run 'vault login', then:"
    echo "          ${REPO_DIR}/channels/install-channels.sh"
fi

echo ""
echo "=== Install complete ==="
echo "To restart channels: systemctl --user restart claude-channels"
echo "To view logs: journalctl --user -u claude-channels -f"
