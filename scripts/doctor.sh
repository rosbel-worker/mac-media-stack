#!/bin/bash
# Media Stack preflight checks (non-destructive)
# Usage: bash scripts/doctor.sh [--media-dir DIR] [--config-dir DIR] [--help]

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
MEDIA_DIR_OVERRIDE=""
CONFIG_DIR_OVERRIDE=""

PASS=0
WARN=0
FAIL=0

# shellcheck source=scripts/lib/media-path.sh
source "$SCRIPT_DIR/scripts/lib/media-path.sh"

usage() {
    cat <<EOF
Usage: bash scripts/doctor.sh [OPTIONS]

Run preflight checks before first startup.

Options:
  --media-dir DIR    Media root path (default: from .env, otherwise ~/Media)
  --config-dir DIR   Local app config path (default: from .env, otherwise ~/home-media-stack/config)
  --help            Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --media-dir)
            if [[ $# -lt 2 || "$2" == --* ]]; then
                echo "Missing value for --media-dir"
                exit 1
            fi
            MEDIA_DIR_OVERRIDE="$2"
            shift 2
            ;;
        --config-dir)
            if [[ $# -lt 2 || "$2" == --* ]]; then
                echo "Missing value for --config-dir"
                exit 1
            fi
            CONFIG_DIR_OVERRIDE="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

if [[ -n "$MEDIA_DIR_OVERRIDE" ]]; then
    MEDIA_DIR="$MEDIA_DIR_OVERRIDE"
fi
if [[ -n "$CONFIG_DIR_OVERRIDE" ]]; then
    CONFIG_DIR="$CONFIG_DIR_OVERRIDE"
fi

MEDIA_DIR="$(resolve_media_dir "$SCRIPT_DIR")"
CONFIG_DIR="$(resolve_config_dir "$SCRIPT_DIR")"

MEDIA_SERVER="$(get_env_value_from_project "MEDIA_SERVER" "$SCRIPT_DIR")"
MEDIA_SERVER="${MEDIA_SERVER:-plex}"
VPN_PROVIDER="$(get_env_value_from_project "VPN_PROVIDER" "$SCRIPT_DIR")"
VPN_PROVIDER="${VPN_PROVIDER:-protonvpn}"

get_env_value() {
    local key="$1"
    sed -n "s/^${key}=//p" "$ENV_FILE" | head -1
}

ok() { echo -e "  ${GREEN}OK${NC}   $1"; PASS=$((PASS + 1)); }
warn() { echo -e "  ${YELLOW}WARN${NC} $1"; WARN=$((WARN + 1)); }
fail() { echo -e "  ${RED}FAIL${NC} $1"; FAIL=$((FAIL + 1)); }

media_reason_text() {
    case "$(media_mount_reason "$SCRIPT_DIR")" in
        missing_mount) echo "Media mount is not present: $MEDIA_DIR" ;;
        missing_subdirs) echo "Media mount is missing required directories under $MEDIA_DIR" ;;
        local_path_missing) echo "Local media path is missing: $MEDIA_DIR" ;;
        *) echo "Media path is unavailable: $MEDIA_DIR" ;;
    esac
}

echo ""
echo "=============================="
echo "  Media Stack Doctor"
echo "=============================="
echo ""
echo -e "  ${CYAN}Info${NC}  Project: $SCRIPT_DIR"
echo -e "  ${CYAN}Info${NC}  Media dir: $MEDIA_DIR"
echo -e "  ${CYAN}Info${NC}  Config dir: $CONFIG_DIR"
echo ""

for cmd in docker curl grep sed awk; do
    if command -v "$cmd" >/dev/null 2>&1; then
        ok "Command found: $cmd"
    else
        fail "Missing command: $cmd"
    fi
done

if docker info >/dev/null 2>&1; then
    runtime=$(docker info --format '{{.OperatingSystem}}' 2>/dev/null || echo "Docker")
    ok "Container runtime running ($runtime)"
else
    fail "Container runtime is not running"
fi

if [[ -f "$ENV_FILE" ]]; then
    ok ".env exists"
    if [[ "$VPN_PROVIDER" == "pia" ]]; then
        vpn_service_provider=$(get_env_value "VPN_SERVICE_PROVIDER")
        vpn_type=$(get_env_value "VPN_TYPE")
        pia_user=$(get_env_value "OPENVPN_USER")
        pia_pass=$(get_env_value "OPENVPN_PASSWORD")

        if [[ "$vpn_service_provider" == "private internet access" ]]; then
            ok "VPN_SERVICE_PROVIDER is set for PIA"
        else
            fail "VPN_SERVICE_PROVIDER must be 'private internet access' when VPN_PROVIDER=pia"
        fi

        if [[ "$vpn_type" == "openvpn" ]]; then
            ok "VPN_TYPE is set to openvpn for PIA"
        else
            fail "VPN_TYPE must be openvpn when VPN_PROVIDER=pia"
        fi

        if [[ -z "$pia_user" ]]; then
            fail "OPENVPN_USER is empty in .env"
        else
            ok "OPENVPN_USER appears set"
        fi
        if [[ -z "$pia_pass" ]]; then
            fail "OPENVPN_PASSWORD is empty in .env"
        else
            ok "OPENVPN_PASSWORD appears set"
        fi
    elif [[ "$VPN_PROVIDER" == "protonvpn" ]]; then
        vpn_service_provider=$(get_env_value "VPN_SERVICE_PROVIDER")
        vpn_type=$(get_env_value "VPN_TYPE")
        wg_private_key=$(get_env_value "WIREGUARD_PRIVATE_KEY")
        wg_addresses=$(get_env_value "WIREGUARD_ADDRESSES")

        if [[ "$vpn_service_provider" == "protonvpn" ]]; then
            ok "VPN_SERVICE_PROVIDER is set for ProtonVPN"
        else
            fail "VPN_SERVICE_PROVIDER must be protonvpn when VPN_PROVIDER=protonvpn"
        fi

        if [[ "$vpn_type" == "wireguard" ]]; then
            ok "VPN_TYPE is set to wireguard for ProtonVPN"
        else
            fail "VPN_TYPE must be wireguard when VPN_PROVIDER=protonvpn"
        fi

        if [[ -z "$wg_private_key" ]]; then
            fail "WIREGUARD_PRIVATE_KEY is empty in .env"
        elif [[ "$wg_private_key" == "your_wireguard_private_key_here" ]]; then
            fail "WIREGUARD_PRIVATE_KEY is still a placeholder in .env"
        else
            ok "WIREGUARD_PRIVATE_KEY appears set"
        fi

        if [[ -z "$wg_addresses" ]]; then
            fail "WIREGUARD_ADDRESSES is empty in .env"
        elif [[ "$wg_addresses" == "your_wireguard_address_here" ]]; then
            fail "WIREGUARD_ADDRESSES is still a placeholder in .env"
        else
            ok "WIREGUARD_ADDRESSES appears set"
        fi
    else
        fail "VPN_PROVIDER must be protonvpn or pia (current: $VPN_PROVIDER)"
    fi
else
    fail ".env is missing (run: bash scripts/setup.sh)"
fi

if media_dir_requires_mount "$SCRIPT_DIR"; then
    if media_mount_ready "$SCRIPT_DIR"; then
        ok "Media mount is present and ready: $MEDIA_DIR"
    else
        fail "$(media_reason_text)"
    fi
else
    if media_mount_ready "$SCRIPT_DIR"; then
        ok "Local media path is ready: $MEDIA_DIR"
    else
        fail "$(media_reason_text)"
    fi
fi

for dir in "$MEDIA_DIR" "$MEDIA_DIR/Downloads" "$MEDIA_DIR/Movies" "$MEDIA_DIR/TV Shows"; do
    if [[ -d "$dir" ]]; then
        ok "Directory exists: $dir"
    else
        if media_dir_requires_mount "$SCRIPT_DIR"; then
            fail "Required media directory missing on mounted path: $dir"
        else
            fail "Required local media directory missing: $dir"
        fi
    fi
done

if [[ -d "$MEDIA_DIR" && ! -w "$MEDIA_DIR" ]]; then
    warn "Media directory is not writable: $MEDIA_DIR"
fi

if [[ -d "$CONFIG_DIR" ]]; then
    ok "Directory exists: $CONFIG_DIR"
else
    warn "Directory missing: $CONFIG_DIR"
fi

config_check_target="$CONFIG_DIR"
if [[ ! -e "$config_check_target" ]]; then
    config_check_target="$(dirname "$CONFIG_DIR")"
fi
config_fs_type="$(stat -f %T "$config_check_target" 2>/dev/null || true)"
if [[ "$config_fs_type" == "smbfs" || "$config_fs_type" == "nfs" ]]; then
    warn "CONFIG_DIR is on $config_fs_type (use local disk to avoid SQLite lock errors)"
fi

if [[ -f "$SCRIPT_DIR/docker-compose.yml" ]] && [[ -f "$ENV_FILE" ]]; then
    if docker compose -f "$SCRIPT_DIR/docker-compose.yml" config >/dev/null 2>&1; then
        ok "docker-compose.yml renders with current .env"
    else
        fail "docker-compose.yml failed to render (check .env values)"
    fi
fi

PORTS=(5055 9696 8989 7878 8080 6767 8191)
if [[ "$MEDIA_SERVER" == "jellyfin" ]]; then
    PORTS+=(8096)
else
    PORTS+=(32400)
fi
for port in "${PORTS[@]}"; do
    owner=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR==2{print $1}' || true)
    if [[ -z "$owner" ]]; then
        ok "Port $port is free"
    else
        warn "Port $port already in use by $owner"
    fi
done

if [[ "$MEDIA_SERVER" == "jellyfin" ]]; then
    ok "Media server: Jellyfin (runs in Docker)"
elif [[ -d "/Applications/Plex Media Server.app" ]] || pgrep -x "Plex Media Server" >/dev/null 2>&1; then
    ok "Plex Media Server detected"
else
    warn "Plex Media Server not detected yet"
fi

echo ""
echo "=============================="
echo -e "  Results: ${GREEN}$PASS passed${NC}, ${YELLOW}$WARN warnings${NC}, ${RED}$FAIL failed${NC}"
echo "=============================="
echo ""

if [[ $FAIL -gt 0 ]]; then
    echo "Resolve FAIL items first, then run this again."
    exit 1
fi

echo "Preflight checks passed."
