#!/bin/bash
# Mac Media Stack - One-Shot Installer
# Usage: curl -fsSL https://raw.githubusercontent.com/liamvibecodes/mac-media-stack/main/bootstrap.sh | bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

BOOTSTRAP_DIR="$(cd "$(dirname "$0")" && pwd)"
MEDIA_DIR="$HOME/Media"
CONFIG_DIR="$HOME/home-media-stack/config"
INSTALL_DIR="$HOME/mac-media-stack"
NON_INTERACTIVE=false
MEDIA_SERVER=plex
VPN_PROVIDER=protonvpn
MEDIA_DIR_SET_BY_FLAG=false
CONFIG_DIR_SET_BY_FLAG=false

usage() {
    cat <<EOF
Usage: bash bootstrap.sh [OPTIONS]

Options:
  --media-dir DIR       Media root path (default: ~/Media)
  --config-dir DIR      Local app config path (default: ~/home-media-stack/config)
  --install-dir DIR     Repo install directory (default: ~/mac-media-stack)
  --jellyfin            Use Jellyfin instead of Plex as your media server
  --pia                 Use PIA instead of ProtonVPN as your VPN provider
  --non-interactive     Skip interactive prompts (manual Seerr wiring required)
  --help                Show this help message

Examples:
  bash bootstrap.sh
  bash bootstrap.sh --media-dir /Volumes/T9/Media
  bash bootstrap.sh --config-dir ~/home-media-stack/config
  bash bootstrap.sh --media-dir /Volumes/T9/Media --non-interactive
  bash bootstrap.sh --jellyfin
  bash bootstrap.sh --pia
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --media-dir)
            if [[ $# -lt 2 || "$2" == --* ]]; then
                echo "Missing value for --media-dir"
                exit 1
            fi
            MEDIA_DIR="$2"
            MEDIA_DIR_SET_BY_FLAG=true
            shift 2
            ;;
        --config-dir)
            if [[ $# -lt 2 || "$2" == --* ]]; then
                echo "Missing value for --config-dir"
                exit 1
            fi
            CONFIG_DIR="$2"
            CONFIG_DIR_SET_BY_FLAG=true
            shift 2
            ;;
        --install-dir)
            if [[ $# -lt 2 || "$2" == --* ]]; then
                echo "Missing value for --install-dir"
                exit 1
            fi
            INSTALL_DIR="$2"
            shift 2
            ;;
        --jellyfin)
            MEDIA_SERVER=jellyfin
            shift
            ;;
        --pia)
            VPN_PROVIDER=pia
            shift
            ;;
        --non-interactive)
            NON_INTERACTIVE=true
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

MEDIA_DIR="${MEDIA_DIR/#\~/$HOME}"
CONFIG_DIR="${CONFIG_DIR/#\~/$HOME}"
INSTALL_DIR="${INSTALL_DIR/#\~/$HOME}"

strip_wrapping_quotes() {
    local value="$1"
    value="${value%\"}"
    value="${value#\"}"
    value="${value%\'}"
    value="${value#\'}"
    printf '%s\n' "$value"
}

if [[ "$MEDIA_DIR_SET_BY_FLAG" != true ]] && [[ -f "$INSTALL_DIR/.env" ]]; then
    env_media_dir="$(sed -n 's/^MEDIA_DIR=//p' "$INSTALL_DIR/.env" | head -1)"
    if [[ -n "$env_media_dir" ]]; then
        MEDIA_DIR="$(strip_wrapping_quotes "$env_media_dir")"
        MEDIA_DIR="${MEDIA_DIR/#\~/$HOME}"
    fi
fi

if [[ "$CONFIG_DIR_SET_BY_FLAG" != true ]] && [[ -f "$INSTALL_DIR/.env" ]]; then
    env_config_dir="$(sed -n 's/^CONFIG_DIR=//p' "$INSTALL_DIR/.env" | head -1)"
    if [[ -n "$env_config_dir" ]]; then
        CONFIG_DIR="$(strip_wrapping_quotes "$env_config_dir")"
        CONFIG_DIR="${CONFIG_DIR/#\~/$HOME}"
    fi
fi

echo ""
echo "=============================="
echo "  Mac Media Stack Installer"
echo "=============================="
echo ""

# Detect container runtime
if [[ -f "$BOOTSTRAP_DIR/scripts/lib/runtime.sh" ]]; then
    # shellcheck source=scripts/lib/runtime.sh
    source "$BOOTSTRAP_DIR/scripts/lib/runtime.sh"
else
    detect_installed_runtime() {
        local has_orbstack=0
        local has_docker_desktop=0

        if [[ -d "/Applications/OrbStack.app" ]] || command -v orbstack &>/dev/null; then
            has_orbstack=1
        fi
        if [[ -d "/Applications/Docker.app" ]]; then
            has_docker_desktop=1
        fi

        if [[ $has_orbstack -eq 1 && $has_docker_desktop -eq 1 ]]; then
            echo "OrbStack or Docker Desktop"
        elif [[ $has_orbstack -eq 1 ]]; then
            echo "OrbStack"
        elif [[ $has_docker_desktop -eq 1 ]]; then
            echo "Docker Desktop"
        else
            echo "none"
        fi
    }

    detect_running_runtime() {
        local os_name
        os_name=$(docker info --format '{{.OperatingSystem}}' 2>/dev/null || true)
        if [[ "$os_name" == *"OrbStack"* ]]; then
            echo "OrbStack"
        elif [[ "$os_name" == *"Docker Desktop"* ]]; then
            echo "Docker Desktop"
        else
            echo "Docker"
        fi
    }

    wait_for_service() {
        local name="$1"
        local url="$2"
        local max_attempts="${3:-45}"
        local attempt=0

        while [[ $attempt -lt $max_attempts ]]; do
            status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "$url" 2>/dev/null || true)
            if [[ "$status" =~ ^(200|301|302|401|403)$ ]]; then
                echo -e "  ${GREEN}OK${NC}  $name is reachable"
                return 0
            fi
            sleep 2
            attempt=$((attempt + 1))
        done

        echo -e "  ${YELLOW}WARN${NC}  $name is not reachable yet (continuing anyway)"
        return 1
    }
fi

INSTALLED_RUNTIME=$(detect_installed_runtime)

if ! docker info &>/dev/null; then
    if [[ "$INSTALLED_RUNTIME" == "none" ]]; then
        echo -e "${RED}No container runtime found.${NC}"
        echo ""
        echo "Install one of these:"
        echo "  OrbStack (recommended):  brew install --cask orbstack"
        echo "  Docker Desktop:          https://www.docker.com/products/docker-desktop/"
    else
        echo -e "${RED}No container runtime is running.${NC}"
        echo "Start $INSTALLED_RUNTIME, wait for it to start, then run this again."
    fi
    exit 1
fi
RUNTIME=$(detect_running_runtime)
echo -e "${GREEN}OK${NC}  $RUNTIME is running"

# Check media server
if [[ "$MEDIA_SERVER" == "jellyfin" ]]; then
    echo -e "${GREEN}OK${NC}  Using Jellyfin (runs in Docker)"
else
    if [[ -d "/Applications/Plex Media Server.app" ]] || pgrep -x "Plex Media Server" &>/dev/null; then
        echo -e "${GREEN}OK${NC}  Plex detected"
    else
        echo -e "${YELLOW}WARN${NC}  Plex not detected. Install from https://www.plex.tv/media-server-downloads/"
        echo "  You can continue and install Plex later."
    fi
fi

# Check git
if ! command -v git &>/dev/null; then
    echo -e "${YELLOW}..${NC}  git not found, installing Command Line Tools..."
    xcode-select --install 2>/dev/null || true
    echo "  Click Install when prompted, then run this again."
    exit 1
fi

echo ""
echo "Install dir: $INSTALL_DIR"
echo "Media dir:   $MEDIA_DIR"
echo "Config dir:  $CONFIG_DIR"
echo ""

# Clone
if [[ -d "$INSTALL_DIR" ]]; then
    echo -e "${YELLOW}Note:${NC} $INSTALL_DIR already exists. Pulling latest..."
    if ! git -C "$INSTALL_DIR" pull --ff-only; then
        echo -e "${RED}Failed to update existing repo at $INSTALL_DIR.${NC}"
        echo "Resolve local git issues, then re-run bootstrap."
        echo "Suggested check: cd $INSTALL_DIR && git status"
        exit 1
    fi
else
    echo -e "${CYAN}Cloning repo...${NC}"
    git clone https://github.com/liamvibecodes/mac-media-stack.git "$INSTALL_DIR"
fi
cd "$INSTALL_DIR"

echo ""

# Setup
echo -e "${CYAN}Running setup...${NC}"
SETUP_ARGS=(--media-dir "$MEDIA_DIR" --config-dir "$CONFIG_DIR")
if [[ "$VPN_PROVIDER" == "pia" ]]; then
    SETUP_ARGS+=(--pia)
fi
bash scripts/setup.sh "${SETUP_ARGS[@]}"

# Write media server choice to .env
if grep -q '^MEDIA_SERVER=' .env 2>/dev/null; then
    sed -i '' "s/^MEDIA_SERVER=.*/MEDIA_SERVER=$MEDIA_SERVER/" .env
else
    echo "" >> .env
    echo "MEDIA_SERVER=$MEDIA_SERVER" >> .env
fi
if grep -q '^CONFIG_DIR=' .env 2>/dev/null; then
    sed -i '' "s|^CONFIG_DIR=.*|CONFIG_DIR=$CONFIG_DIR|" .env
else
    echo "CONFIG_DIR=$CONFIG_DIR" >> .env
fi
if [[ "$MEDIA_SERVER" == "jellyfin" ]]; then
    mkdir -p "$CONFIG_DIR/jellyfin"
fi

# Write VPN provider choice + connection settings to .env
sed -i '' "s/^VPN_PROVIDER=.*/VPN_PROVIDER=$VPN_PROVIDER/" .env
if [[ "$VPN_PROVIDER" == "pia" ]]; then
    sed -i '' "s/^VPN_SERVICE_PROVIDER=.*/VPN_SERVICE_PROVIDER=private internet access/" .env
    sed -i '' "s/^VPN_TYPE=.*/VPN_TYPE=openvpn/" .env
    sed -i '' "s/^SERVER_COUNTRIES=.*/SERVER_COUNTRIES=/" .env
    sed -i '' "s/^SERVER_REGIONS=.*/SERVER_REGIONS=/" .env
    sed -i '' "s/^VPN_PORT_FORWARDING_PROVIDER=.*/VPN_PORT_FORWARDING_PROVIDER=/" .env
    # Gluetun parses WireGuard addresses even when VPN_TYPE=openvpn.
    # Keep these empty for PIA to avoid placeholder parse failures.
    sed -i '' "s/^WIREGUARD_PRIVATE_KEY=.*/WIREGUARD_PRIVATE_KEY=/" .env
    sed -i '' "s/^WIREGUARD_ADDRESSES=.*/WIREGUARD_ADDRESSES=/" .env
else
    sed -i '' "s/^VPN_SERVICE_PROVIDER=.*/VPN_SERVICE_PROVIDER=protonvpn/" .env
    sed -i '' "s/^VPN_TYPE=.*/VPN_TYPE=wireguard/" .env
    sed -i '' "s/^SERVER_COUNTRIES=.*/SERVER_COUNTRIES=United States/" .env
    sed -i '' "s/^SERVER_REGIONS=.*/SERVER_REGIONS=/" .env
    sed -i '' "s/^VPN_PORT_FORWARDING_PROVIDER=.*/VPN_PORT_FORWARDING_PROVIDER=protonvpn/" .env
fi

echo ""

# VPN credentials
if [[ "$VPN_PROVIDER" == "pia" ]]; then
    pia_user=$(sed -n 's/^OPENVPN_USER=//p' .env 2>/dev/null | head -1)
    if [[ -z "$pia_user" ]]; then
        if [[ "$NON_INTERACTIVE" == true ]]; then
            echo -e "${YELLOW}WARN${NC}  Non-interactive mode: PIA credentials not set in .env"
            echo "  Update OPENVPN_USER and OPENVPN_PASSWORD before using the stack."
        else
            echo -e "${CYAN}VPN Configuration (PIA)${NC}"
            echo ""
            echo "You need your PIA (Private Internet Access) credentials."
            echo ""

            pia_user=""
            while [[ -z "$pia_user" ]]; do
                read -p "  PIA Username: " pia_user
                if [[ -z "$pia_user" ]]; then
                    echo -e "  ${RED}Username cannot be empty. Please try again.${NC}"
                fi
            done

            read -s -p "  PIA Password: " pia_pass
            echo ""

            if [[ -n "$pia_pass" ]]; then
                sed -i '' "s|OPENVPN_USER=.*|OPENVPN_USER=$pia_user|" .env
                sed -i '' "s|OPENVPN_PASSWORD=.*|OPENVPN_PASSWORD=$pia_pass|" .env
                echo -e "  ${GREEN}VPN credentials saved${NC}"
            else
                echo -e "  ${YELLOW}Skipped.${NC} Edit .env manually before starting."
                echo "  Run: open -a TextEdit $INSTALL_DIR/.env"
            fi
        fi
    fi
else
    if grep -q "your_wireguard_private_key_here" .env 2>/dev/null; then
        if [[ "$NON_INTERACTIVE" == true ]]; then
            echo -e "${YELLOW}WARN${NC}  Non-interactive mode: VPN placeholders still present in .env"
            echo "  Update WIREGUARD_PRIVATE_KEY and WIREGUARD_ADDRESSES before using the stack."
        else
            echo -e "${CYAN}VPN Configuration (ProtonVPN)${NC}"
            echo ""
            echo "You need your ProtonVPN WireGuard credentials."
            echo "If someone gave you a private key and address, enter them now."
            echo ""

            vpn_key=""
            while [[ -z "$vpn_key" ]]; do
                read -s -p "  WireGuard Private Key: " vpn_key
                echo ""
                if [[ -z "$vpn_key" ]]; then
                    echo -e "  ${RED}Private key cannot be empty. Please try again.${NC}"
                fi
            done

            read -p "  WireGuard Address (e.g. 10.2.0.2/32): " vpn_addr

            if [[ -n "$vpn_addr" ]]; then
                sed -i '' "s|WIREGUARD_PRIVATE_KEY=.*|WIREGUARD_PRIVATE_KEY=$vpn_key|" .env
                sed -i '' "s|WIREGUARD_ADDRESSES=.*|WIREGUARD_ADDRESSES=$vpn_addr|" .env
                echo -e "  ${GREEN}VPN keys saved${NC}"
            else
                echo -e "  ${YELLOW}Skipped.${NC} Edit .env manually before starting."
                echo "  Run: open -a TextEdit $INSTALL_DIR/.env"
            fi
        fi
    fi
fi

echo ""

# Preflight
echo -e "${CYAN}Running preflight checks...${NC}"
if ! bash scripts/doctor.sh --media-dir "$MEDIA_DIR" --config-dir "$CONFIG_DIR"; then
    echo ""
    echo -e "${RED}Preflight checks failed.${NC} Fix the FAIL items above, then re-run bootstrap."
    exit 1
fi

echo ""

# Start stack
echo -e "${CYAN}Starting media stack...${NC}"
echo "  (First run downloads ~2-3 GB, this may take a few minutes)"
echo ""
COMPOSE_CMD=(docker compose)
if [[ "$MEDIA_SERVER" == "jellyfin" ]]; then
    COMPOSE_CMD+=(--profile jellyfin)
fi
COMPOSE_CMD+=(up -d)
if ! "${COMPOSE_CMD[@]}"; then
    echo -e "${RED}Error: docker compose failed to start${NC}"
    echo "Check logs with: docker compose logs"
    exit 1
fi

echo ""
echo "Waiting for core services..."
wait_for_service "qBittorrent" "http://localhost:8080" || true
wait_for_service "Prowlarr" "http://localhost:9696" || true
wait_for_service "Radarr" "http://localhost:7878" || true
wait_for_service "Sonarr" "http://localhost:8989" || true
wait_for_service "Seerr" "http://localhost:5055" || true
if [[ "$MEDIA_SERVER" == "jellyfin" ]]; then
    wait_for_service "Jellyfin" "http://localhost:8096" || true
fi

# Configure
echo ""
if [[ "$NON_INTERACTIVE" == true ]]; then
    bash scripts/configure.sh --non-interactive
else
    bash scripts/configure.sh
fi

# Auto-heal
echo ""
echo -e "${CYAN}Installing auto-healer...${NC}"
bash scripts/install-auto-heal.sh

echo ""
echo "=============================="
echo -e "  ${GREEN}Installation complete!${NC}"
echo "=============================="
echo ""
echo "  Seerr (browse/request):  http://localhost:5055"
if [[ "$MEDIA_SERVER" == "jellyfin" ]]; then
    echo "  Jellyfin (watch):        http://localhost:8096"
else
    echo "  Plex (watch):            http://localhost:32400/web"
fi
echo ""
echo "  Media location:          $MEDIA_DIR"
echo ""
if [[ "$MEDIA_SERVER" == "jellyfin" ]]; then
    echo "  Next: Set up Jellyfin libraries at http://localhost:8096"
    echo "    - Movies: /data/movies"
    echo "    - TV Shows: /data/tvshows"
else
    echo "  Next: Set up Plex libraries (Settings > Libraries > Add)"
    echo "    - Movies: $MEDIA_DIR/Movies"
    echo "    - TV Shows: $MEDIA_DIR/TV Shows"
fi
echo ""
