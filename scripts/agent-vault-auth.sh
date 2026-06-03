#!/usr/bin/env bash
# agent-vault-auth.sh — Phase 3.5 (OPS-347) + Phase 4.5 (OPS-545) + Phase 5 (OPS-630)
# Obtain a scoped Vault token for a single agent role via either:
#   - SPIRE JWT-SVID  → auth/jwt-spire/login     (OPS-545, opt-in)
#   - Keycloak OIDC   → auth/jwt/login            (OPS-347, default)
#   - Authentik OIDC  → auth/jwt-authentik/login  (OPS-630, opt-in)
#
# Backend selection (env var, default keycloak for backward compat):
#   SENTINEL_AUTH_BACKEND=spire              try SPIRE first; fall back to Keycloak
#                                            on any SPIRE-path failure (dual-path,
#                                            OPS-545 D1).
#   SENTINEL_AUTH_BACKEND=spire-only         use SPIRE only; FAIL HARD if it doesn't
#                                            work (no fallback). For strict testing.
#   SENTINEL_AUTH_BACKEND=keycloak           explicit Keycloak only (== default).
#   SENTINEL_AUTH_BACKEND=authentik          Authentik only; FAIL HARD if it doesn't
#                                            work (OPS-630).
#   SENTINEL_AUTH_BACKEND=authentik-keycloak try Authentik first; fall back to Keycloak
#                                            on any Authentik-path failure. Use during
#                                            migration (OPS-630 dual-running phase).
#   (unset / anything else)                  keycloak (unchanged baseline).
#
# Usage:
#   bash scripts/agent-vault-auth.sh <role>
#     role: worker | planner | judge | scribe
#
# Idempotent: if the cached token file is < TOKEN_MAX_AGE seconds old,
# returns the cached file path without re-authenticating.
#
# Session ID:
#   Token file path uses ${SESSION_ID:-default}. Per-session isolation when
#   exported; "default" fallback safe for single-session workstations.
#
# Prerequisites for SPIRE backend:
#   - spire-agent CLI in PATH (or /usr/local/bin/spire-agent)
#   - Workload API socket at /run/spire-agent/agent.sock (overridable via
#     SPIRE_SOCKET_PATH env var)
#   - Process effective UID == sentinel-<role> (Unix attestor SO_PEERCRED).
#     If running as another user, script re-execs itself via:
#       sudo -u sentinel-<role> --preserve-env=VAULT_ADDR,VAULT_SKIP_VERIFY,
#         SESSION_ID,SENTINEL_AUTH_BACKEND -- <script-path> <role>
#     Requires sudoers entry deployed by sentinel-iac role
#     `sentinel-agent-workload` (OPS-545).
#
# Prerequisites for Keycloak backend (unchanged from OPS-347):
#   - VAULT_TOKEN (session root) in env, OR a valid ~/.vault-token
#
# Common prerequisites:
#   - VAULT_ADDR (defaults to https://your-host.example.com)
#   - vault CLI in PATH (or ~/.local/bin/vault)
#   - curl + python3 in PATH (standard on all targets — no jq dependency)
#
# Security notes:
#   - set -x is NOT used (prevents credential echo in debug traces)
#   - Client secret and JWTs cleared from variables after use (best-effort)
#   - Scoped token written via atomic mv + umask 077 (never mode 0644)
#   - SPIRE path: VAULT_TOKEN is NOT propagated through the sudo barrier
#     when re-execing as sentinel-<role>; that user has no business holding
#     the operator's session root token.
#
# Exit codes:
#   0 — success (token file path echoed to stdout)
#   1 — any failure (error details on stderr)

set -euo pipefail

# ── Config ─────────────────────────────────────────────────────────────────────

VAULT_ADDR="${VAULT_ADDR:-https://your-host.example.com}"
export VAULT_ADDR
export VAULT_SKIP_VERIFY="${VAULT_SKIP_VERIFY:-true}"

KEYCLOAK_TOKEN_URL="https://your-host.example.com/realms/sentinel/protocol/openid-connect/token"
AUTHENTIK_TOKEN_URL="https://your-host.example.com/application/o/token/"

CACHE_DIR="${HOME}/.claude/cache"
SESSION_ID="${SESSION_ID:-default}"

# Vault scoped token TTL is 3600 s. Refresh if file is older than 3300 s (55 min).
TOKEN_MAX_AGE=3300

# OPS-545 SPIRE backend config.
SPIRE_SOCKET_PATH="${SPIRE_SOCKET_PATH:-/run/spire-agent/agent.sock}"
VAULT_JWT_SPIRE_AUDIENCE="${VAULT_JWT_SPIRE_AUDIENCE:your-host.example.com}"
SENTINEL_AUTH_BACKEND="${SENTINEL_AUTH_BACKEND:-keycloak}"

# Where the script ultimately lives when deployed by the sentinel-agent-workload
# Ansible role. Used for the sudo re-exec target path.
DEPLOYED_SCRIPT_PATH="/usr/local/bin/agent-vault-auth.sh"

# ── Validate argument ──────────────────────────────────────────────────────────

ROLE="${1:-}"
case "${ROLE}" in
    worker|planner|judge|scribe) ;;
    "")
        echo "[agent-vault-auth] ERROR: role argument required." >&2
        echo "[agent-vault-auth] Usage: bash scripts/agent-vault-auth.sh <worker|planner|judge|scribe>" >&2
        exit 1
        ;;
    *)
        echo "[agent-vault-auth] ERROR: role must be worker|planner|judge|scribe (got: '${ROLE}')" >&2
        exit 1
        ;;
esac

TOKEN_FILE="${CACHE_DIR}/agent-vault-token-${SESSION_ID}-${ROLE}"

# ── Helpers ────────────────────────────────────────────────────────────────────

log() { echo "[agent-vault-auth] $*" >&2; }
err() { echo "[agent-vault-auth] ERROR: $*" >&2; }

# ── Check token cache ──────────────────────────────────────────────────────────

if [[ -f "${TOKEN_FILE}" ]]; then
    FILE_AGE=$(( $(date +%s) - $(stat -c %Y "${TOKEN_FILE}") ))
    if (( FILE_AGE < TOKEN_MAX_AGE )); then
        log "Cached token for role=${ROLE} is ${FILE_AGE}s old (< ${TOKEN_MAX_AGE}s) — reusing."
        echo "${TOKEN_FILE}"
        exit 0
    fi
    log "Cached token for role=${ROLE} is ${FILE_AGE}s old (>= ${TOKEN_MAX_AGE}s) — refreshing."
fi

# ── Pre-flight: common CLIs ────────────────────────────────────────────────────

if ! command -v vault &>/dev/null; then
    if [[ -x "${HOME}/.local/bin/vault" ]]; then
        export PATH="${HOME}/.local/bin:${PATH}"
    else
        err "vault CLI not found in PATH or ~/.local/bin/vault."
        exit 1
    fi
fi

if ! command -v curl &>/dev/null; then
    err "curl not found in PATH."
    exit 1
fi

if ! command -v python3 &>/dev/null; then
    err "python3 not found in PATH."
    exit 1
fi

# ── Helper: write scoped token to cache file (atomic) ──────────────────────────

write_token_to_cache() {
    local _scoped_token="$1"
    if [[ -z "${_scoped_token}" ]]; then
        err "write_token_to_cache called with empty token."
        return 1
    fi
    mkdir -p "${CACHE_DIR}"
    local _saved_umask _tmp_file
    _saved_umask=$(umask)
    umask 077
    _tmp_file=$(mktemp "${CACHE_DIR}/.agent-vault-token.XXXXXXXX")
    umask "${_saved_umask}"
    if printf '%s' "${_scoped_token}" > "${_tmp_file}" \
        && chmod 0600 "${_tmp_file}" \
        && mv -f "${_tmp_file}" "${TOKEN_FILE}"; then
        log "Token written (mode 0600) to ${TOKEN_FILE}."
        return 0
    else
        rm -f "${_tmp_file}" 2>/dev/null || true
        err "Failed to write token file atomically to: ${TOKEN_FILE}"
        return 1
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# ── Backend A: SPIRE JWT-SVID → auth/jwt-spire/login (OPS-545) ────────────────
# ──────────────────────────────────────────────────────────────────────────────

auth_via_spire() {
    log "Trying SPIRE backend (role=${ROLE}, audience=${VAULT_JWT_SPIRE_AUDIENCE})..."

    # 1. spire-agent CLI must be available.
    local _spire_bin
    if command -v spire-agent &>/dev/null; then
        _spire_bin="$(command -v spire-agent)"
    elif [[ -x /usr/local/bin/spire-agent ]]; then
        _spire_bin="/usr/local/bin/spire-agent"
    else
        err "[SPIRE] spire-agent CLI not found in PATH or /usr/local/bin/spire-agent."
        return 1
    fi

    # 2. Workload API socket must exist + be readable.
    if [[ ! -S "${SPIRE_SOCKET_PATH}" ]]; then
        err "[SPIRE] Workload API socket missing at ${SPIRE_SOCKET_PATH}. SPIRE Agent down?"
        return 1
    fi

    # 3. Unix attestor selector check: process EUID must match sentinel-<role>.
    # If not, re-exec via sudo. The sudoers entry deployed by
    # sentinel-agent-workload role is scoped to the deployed script path and
    # is NOPASSWD with setenv for VAULT_ADDR / SESSION_ID / SENTINEL_AUTH_BACKEND.
    local _current_user
    _current_user="$(id -un)"
    if [[ "${_current_user}" != "sentinel-${ROLE}" ]]; then
        log "[SPIRE] current user is '${_current_user}'; re-exec'ing as 'sentinel-${ROLE}' via sudo."

        # CRITICAL SECURITY: do NOT propagate VAULT_TOKEN through the sudo
        # barrier. The session root token has no business landing in the
        # workload user's process env.
        local _script_for_sudo
        if [[ -x "${DEPLOYED_SCRIPT_PATH}" ]]; then
            _script_for_sudo="${DEPLOYED_SCRIPT_PATH}"
        else
            # Repo invocation path (workstation dev/test). The sudoers entry
            # only allows the DEPLOYED_SCRIPT_PATH; if we're invoking from a
            # repo clone, that's a setup error.
            err "[SPIRE] ${DEPLOYED_SCRIPT_PATH} not present; the sudoers entry deployed by"
            err "[SPIRE] sentinel-agent-workload role expects exactly that path."
            err "[SPIRE] Either deploy the script to ${DEPLOYED_SCRIPT_PATH} or"
            err "[SPIRE] invoke this script when already running as sentinel-${ROLE}."
            return 1
        fi

        if sudo -n -u "sentinel-${ROLE}" \
            --preserve-env=VAULT_ADDR,VAULT_SKIP_VERIFY,SESSION_ID,SENTINEL_AUTH_BACKEND,VAULT_JWT_SPIRE_AUDIENCE,SPIRE_SOCKET_PATH \
            -- "${_script_for_sudo}" "${ROLE}"; then
            # The re-exec'd child wrote the cache file and echoed its path.
            # Since the child's stdout has been consumed by our `sudo`, we
            # need to print the path here so our caller sees it.
            echo "${TOKEN_FILE}"
            return 0
        else
            err "[SPIRE] sudo -u sentinel-${ROLE} failed. Sudoers entry missing or NOPASSWD not honored?"
            return 1
        fi
    fi

    # 4. Mint JWT-SVID for the configured audience.
    # The Unix attestor on the Workload API will SO_PEERCRED this process,
    # see UID == sentinel-${ROLE}, and match the workload entry whose
    # selectors are `unix:user:sentinel-${ROLE}` AND
    # `unix:supplementary_group:sentinel-agents`.
    local _svid_json _jwt_svid
    _svid_json=$("${_spire_bin}" api fetch jwt \
        -socketPath "${SPIRE_SOCKET_PATH}" \
        -audience "${VAULT_JWT_SPIRE_AUDIENCE}" \
        -output json 2>&1) || {
        err "[SPIRE] spire-agent api fetch jwt failed: ${_svid_json}"
        return 1
    }

    # Parse JWT out of the JSON response. spire-agent 1.14.6 `fetch jwt
    # -output json` returns a LIST of two objects: index 0 has key
    # `svids` (list of {spiffe_id, svid, hint}); index 1 has key `bundles`
    # (JWKS per trust domain, base64-encoded). Field names verified
    # empirically against the iac-control SPIRE Agent on 2026-05-12.
    # Tolerate the older single-object shape `{svids: [...]}` too, in case
    # an upstream version flips back.
    _jwt_svid=$(printf '%s' "${_svid_json}" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except json.JSONDecodeError as e:
    print(f'JSON parse error: {e}', file=sys.stderr)
    sys.exit(1)

# Find the svids list — either at the top level (single-object shape) or
# in the first element of a list (1.14.x shape).
svids = None
if isinstance(d, dict):
    svids = d.get('svids') or d.get('SVIDs')
elif isinstance(d, list):
    for item in d:
        if isinstance(item, dict) and ('svids' in item or 'SVIDs' in item):
            svids = item.get('svids') or item.get('SVIDs')
            break

if not svids:
    print(f'no svids list found in response: {d}', file=sys.stderr)
    sys.exit(1)

s = svids[0]
jwt = s.get('svid') or s.get('token') or s.get('SVID') or ''
if not jwt:
    print(f'no svid/token field in: {list(s.keys())}', file=sys.stderr)
    sys.exit(1)
print(jwt)
" 2>&1) || {
        err "[SPIRE] Failed to parse JWT-SVID from spire-agent JSON output: ${_jwt_svid}"
        return 1
    }

    log "[SPIRE] JWT-SVID obtained (${#_jwt_svid} chars). Exchanging for Vault token..."

    # 5. Exchange JWT-SVID → Vault scoped token via auth/jwt-spire/login.
    # NOTE: Vault's auth/jwt-spire mount is unauthenticated for the
    # /login endpoint (the JWT is the credential). No VAULT_TOKEN needed.
    local _scoped_token
    _scoped_token=$(VAULT_TOKEN="" vault write -field=token "auth/jwt-spire/login" \
        "role=sentinel-${ROLE}" \
        "jwt=${_jwt_svid}" 2>&1) || {
        err "[SPIRE] Failed to exchange JWT-SVID at auth/jwt-spire/login (role=sentinel-${ROLE}): ${_scoped_token}"
        return 1
    }

    _jwt_svid=""
    unset _jwt_svid

    if [[ -z "${_scoped_token}" ]]; then
        err "[SPIRE] Vault returned empty token for role sentinel-${ROLE}."
        return 1
    fi

    log "[SPIRE] Vault scoped token obtained (${#_scoped_token} chars)."

    if write_token_to_cache "${_scoped_token}"; then
        _scoped_token=""
        unset _scoped_token
        echo "${TOKEN_FILE}"
        return 0
    else
        return 1
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# ── Backend B: Keycloak client_credentials → auth/jwt/login (OPS-347) ─────────
# ──────────────────────────────────────────────────────────────────────────────

auth_via_keycloak() {
    log "Trying Keycloak backend (role=${ROLE})..."

    if [[ -z "${VAULT_TOKEN:-}" ]]; then
        if [[ -f "${HOME}/.vault-token" ]]; then
            # shellcheck disable=SC2155
            export VAULT_TOKEN=$(< "${HOME}/.vault-token")
            log "[KC] Loaded VAULT_TOKEN from ~/.vault-token"
        else
            err "[KC] VAULT_TOKEN is not set and ~/.vault-token does not exist."
            err "[KC] The session root token must be in env or ~/.vault-token."
            return 1
        fi
    fi

    log "[KC] Reading Keycloak client credentials for role=${ROLE} from Vault..."
    log "[KC]   Path: secret/forgejo-${ROLE}"

    local _kc_client_id _kc_client_secret _jwt_response _jwt _scoped_token

    _kc_client_id=$(vault kv get -field=keycloak_client_id "secret/forgejo-${ROLE}" 2>/dev/null) || {
        err "[KC] Failed to read keycloak_client_id from secret/forgejo-${ROLE}."
        return 1
    }

    _kc_client_secret=$(vault kv get -field=keycloak_client_secret "secret/forgejo-${ROLE}" 2>/dev/null) || {
        err "[KC] Failed to read keycloak_client_secret from secret/forgejo-${ROLE}."
        return 1
    }

    if [[ -z "${_kc_client_id}" || -z "${_kc_client_secret}" ]]; then
        err "[KC] Keycloak creds empty after Vault read (path: secret/forgejo-${ROLE})."
        return 1
    fi

    log "[KC] Keycloak client_id=${_kc_client_id} loaded."
    log "[KC] Requesting JWT from Keycloak (client_credentials flow)..."

    _jwt_response=$(curl -sk \
        --request POST \
        --data-urlencode "grant_type=client_credentials" \
        --data-urlencode "client_id=${_kc_client_id}" \
        --data-urlencode "client_secret=${_kc_client_secret}" \
        "${KEYCLOAK_TOKEN_URL}") || {
        err "[KC] curl to Keycloak failed: ${KEYCLOAK_TOKEN_URL}"
        return 1
    }

    _kc_client_secret=""
    unset _kc_client_secret

    if [[ -z "${_jwt_response}" ]]; then
        err "[KC] Keycloak returned empty response body."
        return 1
    fi

    _jwt=$(printf '%s' "${_jwt_response}" | python3 -c "
import json, sys
try:
    r = json.load(sys.stdin)
except json.JSONDecodeError as e:
    print(f'JSON decode error: {e}', file=sys.stderr)
    sys.exit(1)
if 'access_token' not in r:
    err_type = r.get('error', 'unknown_error')
    err_desc = r.get('error_description', 'no description')
    print(f'{err_type}: {err_desc}', file=sys.stderr)
    sys.exit(1)
print(r['access_token'])
" 2>&1) || {
        err "[KC] Failed to extract access_token from Keycloak: ${_jwt}"
        return 1
    }

    if [[ -z "${_jwt}" ]]; then
        err "[KC] Keycloak returned empty access_token."
        return 1
    fi

    log "[KC] JWT obtained (${#_jwt} chars). Exchanging for Vault token (role=sentinel-${ROLE})..."

    _scoped_token=$(vault write -field=token auth/jwt/login \
        "role=sentinel-${ROLE}" \
        "jwt=${_jwt}" 2>/dev/null) || {
        err "[KC] Failed to exchange JWT at auth/jwt/login for role sentinel-${ROLE}."
        return 1
    }

    _jwt=""
    unset _jwt

    if [[ -z "${_scoped_token}" ]]; then
        err "[KC] Vault returned empty token for role sentinel-${ROLE}."
        return 1
    fi

    log "[KC] Vault scoped token obtained (${#_scoped_token} chars)."

    if write_token_to_cache "${_scoped_token}"; then
        _scoped_token=""
        unset _scoped_token
        echo "${TOKEN_FILE}"
        return 0
    else
        return 1
    fi
}


# ──────────────────────────────────────────────────────────────────────────────
# ── Backend C: Authentik client_credentials → auth/jwt-authentik/login (OPS-630) ─
# ──────────────────────────────────────────────────────────────────────────────

auth_via_authentik() {
    log "Trying Authentik backend (role=${ROLE})..."

    if [[ -z "${VAULT_TOKEN:-}" ]]; then
        if [[ -f "${HOME}/.vault-token" ]]; then
            # shellcheck disable=SC2155
            export VAULT_TOKEN=$(< "${HOME}/.vault-token")
            log "[AK] Loaded VAULT_TOKEN from ~/.vault-token"
        else
            err "[AK] VAULT_TOKEN is not set and ~/.vault-token does not exist."
            err "[AK] The session root token must be in env or ~/.vault-token."
            return 1
        fi
    fi

    log "[AK] Reading Authentik client credentials for role=${ROLE} from Vault..."
    log "[AK]   Path: secret/authentik/clients/sentinel-${ROLE}"

    local _ak_client_id _ak_client_secret _jwt_response _jwt _scoped_token

    _ak_client_id=$(vault kv get -field=client_id "secret/authentik/clients/sentinel-${ROLE}" 2>/dev/null) || {
        err "[AK] Failed to read client_id from secret/authentik/clients/sentinel-${ROLE}."
        return 1
    }

    _ak_client_secret=$(vault kv get -field=client_secret "secret/authentik/clients/sentinel-${ROLE}" 2>/dev/null) || {
        err "[AK] Failed to read client_secret from secret/authentik/clients/sentinel-${ROLE}."
        return 1
    }

    if [[ -z "${_ak_client_id}" || -z "${_ak_client_secret}" ]]; then
        err "[AK] Authentik creds empty after Vault read (path: secret/authentik/clients/sentinel-${ROLE})."
        return 1
    fi

    log "[AK] Authentik client_id=${_ak_client_id} loaded."
    log "[AK] Requesting JWT from Authentik (client_credentials flow)..."

    _jwt_response=$(curl -sk \
        --request POST \
        --data-urlencode "grant_type=client_credentials" \
        --data-urlencode "client_id=${_ak_client_id}" \
        --data-urlencode "client_secret=${_ak_client_secret}" \
        --data-urlencode "scope=openid" \
        "${AUTHENTIK_TOKEN_URL}") || {
        err "[AK] curl to Authentik failed: ${AUTHENTIK_TOKEN_URL}"
        return 1
    }

    _ak_client_secret=""
    unset _ak_client_secret

    if [[ -z "${_jwt_response}" ]]; then
        err "[AK] Authentik returned empty response body."
        return 1
    fi

    _jwt=$(printf '%s' "${_jwt_response}" | python3 -c "
import json, sys
try:
    r = json.load(sys.stdin)
except json.JSONDecodeError as e:
    print(f'JSON decode error: {e}', file=sys.stderr)
    sys.exit(1)
if 'access_token' not in r:
    err_type = r.get('error', 'unknown_error')
    err_desc = r.get('error_description', 'no description')
    print(f'{err_type}: {err_desc}', file=sys.stderr)
    sys.exit(1)
print(r['access_token'])
" 2>&1) || {
        err "[AK] Failed to extract access_token from Authentik: ${_jwt}"
        return 1
    }

    if [[ -z "${_jwt}" ]]; then
        err "[AK] Authentik returned empty access_token."
        return 1
    fi

    log "[AK] JWT obtained (${#_jwt} chars). Exchanging for Vault token (role=sentinel-${ROLE})..."

    _scoped_token=$(VAULT_TOKEN="" vault write -field=token auth/jwt-authentik/login \
        "role=sentinel-${ROLE}" \
        "jwt=${_jwt}" 2>/dev/null) || {
        err "[AK] Failed to exchange JWT at auth/jwt-authentik/login for role sentinel-${ROLE}."
        return 1
    }

    _jwt=""
    unset _jwt

    if [[ -z "${_scoped_token}" ]]; then
        err "[AK] Vault returned empty token for role sentinel-${ROLE}."
        return 1
    fi

    log "[AK] Vault scoped token obtained (${#_scoped_token} chars)."

    if write_token_to_cache "${_scoped_token}"; then
        _scoped_token=""
        unset _scoped_token
        echo "${TOKEN_FILE}"
        return 0
    else
        return 1
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# ── Backend selection + dual-path orchestration ───────────────────────────────
# ──────────────────────────────────────────────────────────────────────────────

case "${SENTINEL_AUTH_BACKEND}" in
    spire)
        # Dual-path: SPIRE first, Keycloak fallback on any failure.
        if auth_via_spire; then
            exit 0
        fi
        log "SPIRE backend failed — falling back to Keycloak (dual-path)."
        if auth_via_keycloak; then
            exit 0
        fi
        err "Both SPIRE and Keycloak backends failed."
        exit 1
        ;;
    spire-only)
        # Strict mode: SPIRE only, no fallback. For testing the SPIRE path
        # without the Keycloak safety net masking failures.
        if auth_via_spire; then
            exit 0
        fi
        err "SPIRE-only backend failed (SENTINEL_AUTH_BACKEND=spire-only, no fallback)."
        exit 1
        ;;
    keycloak|"")
        # Default: existing OPS-347 behavior unchanged.
        if auth_via_keycloak; then
            exit 0
        fi
        err "Keycloak backend failed."
        exit 1
        ;;
    authentik)
        # Authentik only; no fallback (OPS-630).
        if auth_via_authentik; then
            exit 0
        fi
        err "Authentik backend failed (SENTINEL_AUTH_BACKEND=authentik)."
        exit 1
        ;;
    authentik-keycloak)
        # Dual-path: Authentik first; Keycloak fallback (OPS-630 migration phase).
        if auth_via_authentik; then
            exit 0
        fi
        log "Authentik backend failed — falling back to Keycloak (dual-path)."
        if auth_via_keycloak; then
            exit 0
        fi
        err "Both Authentik and Keycloak backends failed."
        exit 1
        ;;
    *)
        err "Unknown SENTINEL_AUTH_BACKEND='${SENTINEL_AUTH_BACKEND}'."
        err "Valid: spire | spire-only | keycloak | authentik | authentik-keycloak | (unset==keycloak)"
        exit 1
        ;;
esac
