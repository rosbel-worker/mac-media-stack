#!/bin/bash
# Media Stack Setup Helper
# Creates all required folders and prepares the .env file.
# Usage: bash scripts/setup.sh [--media-dir DIR] [--pia] [--help]

set -e

YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

usage() {
    cat <<EOF
Usage: bash scripts/setup.sh [OPTIONS]

Creates Media folder structure and generates .env from .env.example.

Options:
  --media-dir DIR   Media root path (default: ~/Media)
  --pia             Configure .env for PIA (OpenVPN) instead of ProtonVPN
  --help            Show this help message
EOF
}

MEDIA_DIR_OVERRIDE=""
VPN_PROVIDER_OVERRIDE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --media-dir)
            if [[ $# -lt 2 || "$2" == --* ]]; then
                echo "Missing value for --media-dir"
                usage
                exit 1
            fi
            MEDIA_DIR_OVERRIDE="$2"
            shift 2
            ;;
        --pia)
            VPN_PROVIDER_OVERRIDE="pia"
            shift
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

echo ""
echo "=============================="
echo "  Media Stack Setup"
echo "=============================="
echo ""

# Detect current user and home directory
CURRENT_USER=$(whoami)
HOME_DIR=$(eval echo ~$CURRENT_USER)
MEDIA_DIR="${MEDIA_DIR_OVERRIDE:-$HOME_DIR/Media}"
MEDIA_DIR="${MEDIA_DIR/#\~/$HOME}"

echo "Detected user: $CURRENT_USER"
echo "Media folder will be: $MEDIA_DIR"
echo ""

# Get user ID
USER_PUID=$(id -u)
USER_PGID=$(id -g)

# Create folder structure
echo "Creating folders..."
mkdir -p "$MEDIA_DIR"/{config,Downloads,Movies,"TV Shows",logs}
mkdir -p "$MEDIA_DIR"/config/{qbittorrent,prowlarr,sonarr,radarr,bazarr,seerr}
echo -e "  ${GREEN}Done${NC}"
echo ""

# Create .env from example if it doesn't exist
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

if [[ -f "$ENV_FILE" ]]; then
    echo -e "${YELLOW}Note:${NC} .env already exists. Skipping creation."
    echo "  Edit it manually if you need to change values."
else
    echo "Creating .env file..."
    sed "s|/Users/YOURUSERNAME/Media|$MEDIA_DIR|g" "$SCRIPT_DIR/.env.example" \
        | sed "s|PUID=501|PUID=$USER_PUID|g" \
        | sed "s|PGID=20|PGID=$USER_PGID|g" \
        > "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    echo -e "  ${GREEN}Done${NC}"
    echo ""
fi

# Keep existing .env in sync with any newly added keys from .env.example.
added_keys=()
while IFS= read -r line; do
    [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
    key="${line%%=*}"
    if ! grep -q "^${key}=" "$ENV_FILE"; then
        echo "$line" >> "$ENV_FILE"
        added_keys+=("$key")
    fi
done < "$SCRIPT_DIR/.env.example"

if [[ "${#added_keys[@]}" -gt 0 ]]; then
    echo -e "${YELLOW}Note:${NC} Added missing .env keys from .env.example:"
    for key in "${added_keys[@]}"; do
        echo "  - $key"
    done
    echo ""
fi

set_env_key() {
    local key="$1"
    local value="$2"
    local escaped_value="${value//&/\\&}"
    escaped_value="${escaped_value//|/\\|}"
    if grep -q "^${key}=" "$ENV_FILE"; then
        sed -i '' "s|^${key}=.*|${key}=${escaped_value}|" "$ENV_FILE"
    else
        echo "${key}=${value}" >> "$ENV_FILE"
    fi
}

get_env_key() {
    local key="$1"
    sed -n "s/^${key}=//p" "$ENV_FILE" | head -1
}

if [[ "$VPN_PROVIDER_OVERRIDE" == "pia" ]]; then
    set_env_key "VPN_PROVIDER" "pia"
    set_env_key "VPN_SERVICE_PROVIDER" "private internet access"
    set_env_key "VPN_TYPE" "openvpn"
    set_env_key "SERVER_COUNTRIES" ""
    set_env_key "SERVER_REGIONS" ""
    set_env_key "VPN_PORT_FORWARDING_PROVIDER" ""
    # Gluetun parses WireGuard addresses even when using OpenVPN.
    # Clear placeholders to prevent parse errors on startup.
    set_env_key "WIREGUARD_PRIVATE_KEY" ""
    set_env_key "WIREGUARD_ADDRESSES" ""
else
    # If provider is already set to PIA, normalize obvious Proton defaults
    # that may have been added from .env.example during sync.
    current_vpn_provider="$(get_env_key "VPN_PROVIDER")"
    if [[ "$current_vpn_provider" == "pia" ]]; then
        vpn_service_provider="$(get_env_key "VPN_SERVICE_PROVIDER")"
        vpn_type="$(get_env_key "VPN_TYPE")"
        server_countries="$(get_env_key "SERVER_COUNTRIES")"
        server_regions="$(get_env_key "SERVER_REGIONS")"
        vpn_pf_provider="$(get_env_key "VPN_PORT_FORWARDING_PROVIDER")"
        wg_private_key="$(get_env_key "WIREGUARD_PRIVATE_KEY")"
        wg_addresses="$(get_env_key "WIREGUARD_ADDRESSES")"

        if [[ -z "$vpn_service_provider" || "$vpn_service_provider" == "protonvpn" ]]; then
            set_env_key "VPN_SERVICE_PROVIDER" "private internet access"
        fi
        if [[ -z "$vpn_type" || "$vpn_type" == "wireguard" ]]; then
            set_env_key "VPN_TYPE" "openvpn"
        fi
        if [[ "$server_countries" == "United States" ]]; then
            set_env_key "SERVER_COUNTRIES" ""
        fi
        # Leave SERVER_REGIONS empty by default for PIA so the port-forward-only
        # filter can match any valid region.
        if [[ "$vpn_pf_provider" == "protonvpn" ]]; then
            set_env_key "VPN_PORT_FORWARDING_PROVIDER" ""
        fi
        if [[ "$wg_private_key" == "your_wireguard_private_key_here" ]]; then
            set_env_key "WIREGUARD_PRIVATE_KEY" ""
        fi
        if [[ "$wg_addresses" == "your_wireguard_address_here" ]]; then
            set_env_key "WIREGUARD_ADDRESSES" ""
        fi
    fi
fi

# Read VPN_PROVIDER from .env for setup messaging.
vpn_provider=$(sed -n 's/^VPN_PROVIDER=//p' "$ENV_FILE" | head -1)
vpn_provider="${vpn_provider:-protonvpn}"
echo -e "${YELLOW}IMPORTANT:${NC} You still need to add your VPN credentials to .env"
echo "  Open .env in a text editor and fill in:"
if [[ "$vpn_provider" == "pia" ]]; then
    echo "    - OPENVPN_USER and OPENVPN_PASSWORD (from your PIA account)"
else
    echo "    - WIREGUARD_PRIVATE_KEY and WIREGUARD_ADDRESSES (from your ProtonVPN account)"
fi

echo ""
echo "=============================="
echo "  Setup complete!"
echo "=============================="
echo ""
echo "Next steps:"
echo "  1. Add VPN credentials to .env (if not already done)"
echo "  2. Run: docker compose up -d"
echo "     (or: docker compose --profile jellyfin up -d if MEDIA_SERVER=jellyfin)"
echo "  3. Run: bash scripts/health-check.sh"
echo "  4. Follow the rest of SETUP.md for Plex + app configuration"
echo ""
