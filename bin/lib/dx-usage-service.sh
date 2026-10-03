#!/usr/bin/env bash
# Host side of the usage service (docs/refactor/usage-service-host.md design
# item 5): start/stop/restart/status/logs for the guest's agent-stats service,
# through dx_runtime_exec to the s6 tools the guest's service directory points
# at. Safe to source; bin/dx-usage-service is the entrypoint.

DX_USAGE_HOST_SCAN_DIR=/run/dx-services
DX_USAGE_HOST_LOG_FILE=/persist/services/agent-stats/logs/agent-stats/current

# bin/dx-create-container: two published host ports cannot be the same port,
# so DX_USAGE_SERVICE=on with a host port equal to DX_SSH_PORT is refused
# before the runtime is touched. Off ignores DX_USAGE_SERVICE_HOST_PORT.
dx_usage_host_create_check() {
    [ "$DX_USAGE_SERVICE" = on ] && [ "$DX_USAGE_SERVICE_HOST_PORT" = "$DX_SSH_PORT" ] || return 0
    echo "Error: DX_USAGE_SERVICE_HOST_PORT ($DX_USAGE_SERVICE_HOST_PORT) must differ from DX_SSH_PORT ($DX_SSH_PORT); both are published by the same container." >&2
    return 1
}

# Appends the usage service's create items to the caller's CREATE_ARGS array
# (a global in bin/dx-create-container): a second publication through the SAME
# neutral vocabulary as SSH -- no bind address; each adapter prepends its own
# (Apple loopback, docker-ssh the discovered Tailscale address) -- plus the
# env token the guest reads. Off appends nothing, so the rendered create argv
# is byte-identical to before.
dx_usage_host_create_args() {
    [ "$DX_USAGE_SERVICE" = on ] || return 0
    CREATE_ARGS+=(--publish "$DX_USAGE_SERVICE_HOST_PORT:8787" --env "DX_USAGE_SERVICE=on")
}

dx_usage_host_usage() {
    cat <<'USAGE'
Usage: dx-usage-service <start|stop|restart|status|logs [N]>

  start|stop|restart  bring the agent-stats service up, down or restart it
                      (only agent-stats: sshd and the keyring are untouched)
  status              print agent-stats's s6 state
  logs [N]            the last N (default 50) lines of agent-stats's current log
USAGE
}

dx_usage_host_main() {
    local command="${1:-}" lines=50 service="$DX_USAGE_HOST_SCAN_DIR/agent-stats" s6="$DX_USAGE_HOST_SCAN_DIR/.s6-bin"
    case "$command" in
        start|stop|restart|status) [ "$#" -eq 1 ] || { dx_usage_host_usage >&2; return 64; } ;;
        logs)
            [ "$#" -le 2 ] || { dx_usage_host_usage >&2; return 64; }
            if [ "$#" -eq 2 ]; then
                case "$2" in ""|*[!0-9]*|0*) dx_usage_host_usage >&2; return 64 ;; esac
                [ "${#2}" -le 4 ] || { dx_usage_host_usage >&2; return 64; }
                lines="$2"
            fi
            ;;
        *) dx_usage_host_usage >&2; return 64 ;;
    esac

    dx_runtime_capability usage_service || {
        echo "Error: dx-usage-service is not supported under DX_RUNTIME=${DX_RUNTIME:-apple}: the runtime has no usage_service capability (docker-ssh only)." >&2
        return 1
    }
    dx_runtime_exec "$DX_CONTAINER_NAME" test -d "$service" || {
        echo "Error: $DX_CONTAINER_NAME is not in usage-service mode (no $service), or it is not running. Set DX_USAGE_SERVICE=on in the profile and recreate the container to enable it." >&2
        return 1
    }
    case "$command" in
        start) dx_runtime_exec "$DX_CONTAINER_NAME" "$s6/s6-svc" -u "$service" ;;
        stop) dx_runtime_exec "$DX_CONTAINER_NAME" "$s6/s6-svc" -d "$service" ;;
        restart) dx_runtime_exec "$DX_CONTAINER_NAME" "$s6/s6-svc" -r "$service" ;;
        status) dx_runtime_exec "$DX_CONTAINER_NAME" "$s6/s6-svstat" "$service" ;;
        logs) dx_runtime_exec "$DX_CONTAINER_NAME" tail -n "$lines" "$DX_USAGE_HOST_LOG_FILE" ;;
    esac
}
