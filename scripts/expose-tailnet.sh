#!/bin/bash
# Expose locally bound media stack UIs to a Tailscale tailnet using tailscale serve.
# Usage: bash scripts/expose-tailnet.sh [--disable|--status] [--include-flaresolverr]

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

MODE="enable"
INCLUDE_FLARESOLVERR=false

usage() {
    cat <<'EOF'
Usage: bash scripts/expose-tailnet.sh [OPTIONS]

Expose the media stack's locally bound web UIs to your Tailscale tailnet
without changing the Docker port bindings.

Options:
  --disable              Remove the tailnet exposure for the media stack ports
  --status               Show the node hostname plus candidate tailnet URLs
  --include-flaresolverr Also expose FlareSolverr (internal/debug use only)
  --help                 Show this help message
EOF
}

fail() {
    echo -e "${RED}Error:${NC} $*" >&2
    exit 1
}

warn() {
    echo -e "${YELLOW}$*${NC}"
}

ok() {
    echo -e "${GREEN}$*${NC}"
}

info() {
    echo -e "${CYAN}$*${NC}"
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

port_is_open() {
    local port="$1"
    nc -z 127.0.0.1 "$port" >/dev/null 2>&1
}

load_tailscale_status() {
    local parsed

    TS_STATUS_JSON="$(tailscale status --json 2>/dev/null)" || fail "Tailscale is not running. Start Tailscale and connect this Mac to your tailnet first."
    parsed="$("$PYTHON_BIN" -c '
import json
import sys

data = json.load(sys.stdin)
self = data.get("Self") or {}
print(data.get("BackendState", ""))
print((self.get("DNSName") or "").rstrip("."))
print(self.get("ID", ""))
' <<<"$TS_STATUS_JSON")"

    TS_BACKEND_STATE="$(printf '%s\n' "$parsed" | sed -n '1p')"
    TS_DNS_NAME="$(printf '%s\n' "$parsed" | sed -n '2p')"
    TS_NODE_ID="$(printf '%s\n' "$parsed" | sed -n '3p')"

    [[ -n "$TS_DNS_NAME" ]] || fail "Unable to determine this node's Tailscale DNS name."
    [[ "$TS_BACKEND_STATE" == "Running" ]] || fail "Tailscale backend state is '$TS_BACKEND_STATE'. Connect the node first."
}

collect_services() {
    ACTIVE_SPECS=()

    for spec in "${SERVICE_SPECS[@]}"; do
        local name port label path
        IFS='|' read -r name port label path <<<"$spec"
        if port_is_open "$port"; then
            ACTIVE_SPECS+=("$spec")
        fi
    done
}

run_with_timeout() {
    local timeout_seconds="$1"
    shift

    local output_file command_pid timer_pid status
    output_file="$(mktemp)"
    status=0

    "$@" >"$output_file" 2>&1 &
    command_pid=$!

    (
        sleep "$timeout_seconds"
        if kill -0 "$command_pid" >/dev/null 2>&1; then
            kill "$command_pid" >/dev/null 2>&1 || true
        fi
    ) &
    timer_pid=$!

    set +e
    wait "$command_pid" 2>/dev/null
    status=$?
    set -e

    kill "$timer_pid" >/dev/null 2>&1 || true

    RUN_OUTPUT="$(cat "$output_file")"
    rm -f "$output_file"

    return "$status"
}

print_enable_hint_and_exit() {
    echo ""
    warn "Tailscale Serve/HTTPS is not enabled for this tailnet yet."
    echo "Open this once as a tailnet admin or owner, then rerun this script:"
    echo "  https://login.tailscale.com/f/serve?node=$TS_NODE_ID"
    exit 1
}

enable_services() {
    local exposed_count
    exposed_count=0

    if [[ "${#ACTIVE_SPECS[@]}" -eq 0 ]]; then
        fail "No locally listening media-stack services were detected. Start the stack first with 'docker compose up -d'."
    fi

    info "Publishing media-stack UIs to $TS_DNS_NAME via tailscale serve..."

    for spec in "${ACTIVE_SPECS[@]}"; do
        local name port label path url
        IFS='|' read -r name port label path <<<"$spec"
        url="https://$TS_DNS_NAME:$port$path"

        if run_with_timeout 8 tailscale serve --bg --yes --https="$port" "http://127.0.0.1:$port"; then
            ok "Exposed $label at $url"
            exposed_count=$((exposed_count + 1))
            continue
        fi

        if [[ "$RUN_OUTPUT" == *"Serve is not enabled on your tailnet."* ]]; then
            print_enable_hint_and_exit
        fi

        fail "Failed to expose $label on port $port. tailscale output: ${RUN_OUTPUT:-<no output>}"
    done

    echo ""
    echo "Tailnet URLs:"
    for spec in "${ACTIVE_SPECS[@]}"; do
        local name port label path
        IFS='|' read -r name port label path <<<"$spec"
        echo "  - $label: https://$TS_DNS_NAME:$port$path"
    done
    echo ""
    echo "To remove these mappings later:"
    echo "  bash scripts/expose-tailnet.sh --disable"

    if [[ "$exposed_count" -eq 0 ]]; then
        warn "No services were exposed."
    fi
}

disable_services() {
    local cleared_any
    cleared_any=false

    info "Removing media-stack tailnet exposure from $TS_DNS_NAME..."

    for spec in "${SERVICE_SPECS[@]}"; do
        local name port label path
        IFS='|' read -r name port label path <<<"$spec"

        if run_with_timeout 8 tailscale serve --yes --https="$port" off; then
            ok "Removed $label from tailnet exposure"
            cleared_any=true
            continue
        fi

        if [[ "$RUN_OUTPUT" == *"Serve is not enabled on your tailnet."* ]]; then
            print_enable_hint_and_exit
        fi

        if [[ "$RUN_OUTPUT" == *"does not exist"* ]] || [[ "$RUN_OUTPUT" == *"no serve config"* ]]; then
            continue
        fi

        fail "Failed to remove $label from port $port. tailscale output: ${RUN_OUTPUT:-<no output>}"
    done

    if [[ "$cleared_any" == true ]]; then
        echo ""
        ok "Media-stack tailnet exposure removed."
    else
        warn "No media-stack tailnet mappings were configured on this node."
    fi
}

show_status() {
    echo "Tailscale node: $TS_DNS_NAME"
    echo ""

    if [[ "${#ACTIVE_SPECS[@]}" -eq 0 ]]; then
        warn "No locally listening media-stack services were detected."
    else
        echo "Detected local services:"
        for spec in "${ACTIVE_SPECS[@]}"; do
            local name port label path
            IFS='|' read -r name port label path <<<"$spec"
            echo "  - $label"
            echo "    local:   http://localhost:$port$path"
            echo "    tailnet: https://$TS_DNS_NAME:$port$path"
        done
        echo ""
    fi

    echo "Current tailscale serve status:"
    tailscale serve status
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --disable)
            MODE="disable"
            shift
            ;;
        --status)
            MODE="status"
            shift
            ;;
        --include-flaresolverr)
            INCLUDE_FLARESOLVERR=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
done

require_cmd "tailscale"
require_cmd "nc"
PYTHON_BIN="$(command -v python3 || true)"
[[ -n "$PYTHON_BIN" ]] || fail "python3 is required to parse Tailscale status output."

SERVICE_SPECS=(
    "seerr|5055|Seerr|"
    "qbittorrent|8080|qBittorrent|"
    "prowlarr|9696|Prowlarr|"
    "sonarr|8989|Sonarr|"
    "radarr|7878|Radarr|"
    "bazarr|6767|Bazarr|"
    "plex|32400|Plex|/web"
    "jellyfin|8096|Jellyfin|"
)

if [[ "$INCLUDE_FLARESOLVERR" == true ]]; then
    SERVICE_SPECS+=("flaresolverr|8191|FlareSolverr|")
fi

load_tailscale_status
collect_services

case "$MODE" in
    enable)
        enable_services
        ;;
    disable)
        disable_services
        ;;
    status)
        show_status
        ;;
esac
