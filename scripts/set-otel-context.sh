#!/usr/bin/env bash
# set-otel-context.sh — set OTEL resource attributes for Plane↔Langfuse audit correlation.
#
# This file MUST be sourced, not executed. The OpenTelemetry SDK reads
# OTEL_RESOURCE_ATTRIBUTES at process start; setting it after `claude` is
# already running has no effect on emitted traces.
#
# Usage:
#   source scripts/set-otel-context.sh OPS-189 worker
#   source scripts/set-otel-context.sh OPS-189 operator agent-name-override
#
# Args:
#   $1  PLANE_ISSUE  e.g. OPS-189 (must match {OPS|SEC|COMP|HAIST}-N)
#   $2  AGENT_ROLE   planner|worker|judge|scribe|operator   (default: operator)
#   $3  AGENT_ID     free-form identifier                  (default: $USER-$HOSTNAME-$$)
#
# Exports OTEL_RESOURCE_ATTRIBUTES with:
#   plane.issue_id, agent.role, agent.id, workspace
#
# Existing OTEL_RESOURCE_ATTRIBUTES values are preserved (appended to).

# Refuse to run when executed instead of sourced.
(return 0 2>/dev/null) || {
    echo "set-otel-context.sh must be SOURCED, not executed." >&2
    echo "Usage: source $0 OPS-189 worker" >&2
    exit 1
}

set_otel_context() {
    local plane_issue="${1:-}"
    local agent_role="${2:-operator}"
    local agent_id="${3:-${USER:-unknown}-${HOSTNAME:-unknown}-$$}"

    if [[ -z "$plane_issue" ]]; then
        echo "set-otel-context: PLANE_ISSUE required (e.g. OPS-189)" >&2
        return 1
    fi

    if ! [[ "$plane_issue" =~ ^(OPS|SEC|COMP|HAIST)-[0-9]+$ ]]; then
        echo "set-otel-context: PLANE_ISSUE must match {OPS|SEC|COMP|HAIST}-N (got: $plane_issue)" >&2
        return 1
    fi

    case "$agent_role" in
        planner|worker|judge|scribe|operator) ;;
        *)
            echo "set-otel-context: AGENT_ROLE must be planner|worker|judge|scribe|operator (got: $agent_role)" >&2
            return 1
            ;;
    esac

    local new_attrs="plane.issue_id=${plane_issue},agent.role=${agent_role},agent.id=${agent_id},workspace=haists-it-consulting"

    if [[ -n "${OTEL_RESOURCE_ATTRIBUTES:-}" ]]; then
        export OTEL_RESOURCE_ATTRIBUTES="${OTEL_RESOURCE_ATTRIBUTES},${new_attrs}"
    else
        export OTEL_RESOURCE_ATTRIBUTES="${new_attrs}"
    fi

    echo "OTEL audit context set:"
    echo "  plane.issue_id = ${plane_issue}"
    echo "  agent.role     = ${agent_role}"
    echo "  agent.id       = ${agent_id}"
    echo "  workspace      = haists-it-consulting"
}

set_otel_context "$@"
