#!/bin/bash
# Media Stack Health Check
# Run this anytime to check if everything is working.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/runtime.sh
source "$SCRIPT_DIR/scripts/lib/runtime.sh"

# Load media server choice
if [[ -f "$SCRIPT_DIR/.env" ]]; then
    MEDIA_SERVER=$(sed -n 's/^MEDIA_SERVER=//p' "$SCRIPT_DIR/.env" | head -1)
fi
MEDIA_SERVER="${MEDIA_SERVER:-plex}"

# Load VPN provider choice
if [[ -f "$SCRIPT_DIR/.env" ]]; then
    VPN_PROVIDER=$(sed -n 's/^VPN_PROVIDER=//p' "$SCRIPT_DIR/.env" | head -1)
fi
VPN_PROVIDER="${VPN_PROVIDER:-protonvpn}"

echo ""
echo "=============================="
echo "  Media Stack Health Check"
echo "=============================="
echo ""

PASS=0
FAIL=0

check_service() {
    local name="$1"
    local url="$2"
    local expected="${3:-200}"

    status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null)
    if [[ "$status" == "$expected" || "$status" == "301" || "$status" == "302" || "$status" == "307" || "$status" == "308" ]]; then
        echo -e "  ${GREEN}OK${NC}  $name"
        ((PASS++))
    else
        echo -e "  ${RED}FAIL${NC}  $name (got HTTP $status)"
        ((FAIL++))
    fi
}

get_netns_id() {
    local name="$1"
    docker exec "$name" sh -lc 'readlink /proc/1/ns/net 2>/dev/null || true' 2>/dev/null \
        | awk -F'[][]' '/^net:\[[0-9]+\]$/ {print $2; exit}'
}

RUNTIME=$(detect_installed_runtime)

if docker info &>/dev/null; then
    RUNTIME=$(detect_running_runtime)
    echo -e "  ${GREEN}OK${NC}  $RUNTIME"
    ((PASS++))
else
    echo -e "  ${RED}FAIL${NC}  $RUNTIME (not running)"
    echo ""
    echo "Start $RUNTIME and try again."
    exit 1
fi

echo ""

# Check containers are running
echo "Containers:"
for name in gluetun qbittorrent prowlarr sonarr radarr bazarr flaresolverr seerr; do
    state=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null)
    if [[ "$state" == "running" ]]; then
        echo -e "  ${GREEN}OK${NC}  $name"
        ((PASS++))
    else
        echo -e "  ${RED}FAIL${NC}  $name (${state:-not found})"
        ((FAIL++))
    fi
done

if [[ "$MEDIA_SERVER" == "jellyfin" ]]; then
    jf_state=$(docker inspect -f '{{.State.Status}}' jellyfin 2>/dev/null)
    if [[ "$jf_state" == "running" ]]; then
        echo -e "  ${GREEN}OK${NC}  jellyfin"
        ((PASS++))
    else
        echo -e "  ${RED}FAIL${NC}  jellyfin (${jf_state:-not found})"
        ((FAIL++))
    fi
fi

watchtower_state=$(docker inspect -f '{{.State.Status}}' watchtower 2>/dev/null || true)
if [[ "$watchtower_state" == "running" ]]; then
    echo -e "  ${GREEN}OK${NC}  watchtower (autoupdate profile enabled)"
    ((PASS++))
else
    echo -e "  ${YELLOW}SKIP${NC}  watchtower (optional; enable with --profile autoupdate)"
fi

echo ""
echo "Web UIs:"
check_service "qBittorrent" "http://localhost:8080"
check_service "Prowlarr" "http://localhost:9696"
check_service "Sonarr" "http://localhost:8989"
check_service "Radarr" "http://localhost:7878"
check_service "Bazarr" "http://localhost:6767"
check_service "Seerr" "http://localhost:5055"

echo ""
echo "VPN:"
echo "  Provider: $VPN_PROVIDER"
vpn_ip=$(docker exec gluetun sh -lc 'cat /tmp/gluetun/ip 2>/dev/null || true' 2>/dev/null)
vpn_iface=$(docker exec gluetun sh -lc 'ls /sys/class/net 2>/dev/null | grep -E "^(tun|wg)[0-9]+$" | head -1' 2>/dev/null)
vpn_health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}unknown{{end}}' gluetun 2>/dev/null || true)
if [[ -n "$vpn_ip" && -n "$vpn_iface" && "$vpn_health" != "unhealthy" ]]; then
    echo -e "  ${GREEN}OK${NC}  VPN active (IP: $vpn_ip, iface: $vpn_iface, health: ${vpn_health:-unknown})"
    ((PASS++))
elif [[ -z "$vpn_ip" ]]; then
    echo -e "  ${RED}FAIL${NC}  VPN not connected (missing /tmp/gluetun/ip)"
    ((FAIL++))
elif [[ -z "$vpn_iface" ]]; then
    echo -e "  ${RED}FAIL${NC}  VPN tunnel interface not detected in gluetun"
    ((FAIL++))
else
    echo -e "  ${RED}FAIL${NC}  VPN health is unhealthy"
    ((FAIL++))
fi

gluetun_netns="$(get_netns_id gluetun)"
qbittorrent_netns="$(get_netns_id qbittorrent)"
if [[ -n "$gluetun_netns" && -n "$qbittorrent_netns" ]]; then
    if [[ "$gluetun_netns" == "$qbittorrent_netns" ]]; then
        echo -e "  ${GREEN}OK${NC}  qBittorrent shares gluetun network namespace ($gluetun_netns)"
        ((PASS++))
    else
        echo -e "  ${RED}FAIL${NC}  qBittorrent network namespace drift (gluetun=$gluetun_netns, qbittorrent=$qbittorrent_netns)"
        echo "       Run: docker restart qbittorrent"
        ((FAIL++))
    fi
else
    echo -e "  ${YELLOW}SKIP${NC}  Could not verify qBittorrent/gluetun namespace IDs"
fi

echo ""
if [[ "$MEDIA_SERVER" == "jellyfin" ]]; then
    echo "Jellyfin:"
    jf_status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://localhost:8096/health" 2>/dev/null)
    if [[ "$jf_status" == "200" ]]; then
        echo -e "  ${GREEN}OK${NC}  Jellyfin (http://localhost:8096)"
        ((PASS++))
    else
        echo -e "  ${YELLOW}SKIP${NC}  Jellyfin not reachable yet (may still be starting)"
    fi
else
    echo "Plex:"
    plex_status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://localhost:32400/web" 2>/dev/null)
    if [[ "$plex_status" == "200" || "$plex_status" == "302" || "$plex_status" == "301" ]]; then
        echo -e "  ${GREEN}OK${NC}  Plex (http://localhost:32400/web)"
        ((PASS++))
    else
        echo -e "  ${YELLOW}SKIP${NC}  Plex not detected (install separately, see SETUP.md)"
    fi
fi

echo ""
echo "=============================="
echo -e "  Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
echo "=============================="
echo ""

if [[ $FAIL -gt 0 ]]; then
    echo "Something's not right. Check the FAIL items above."
    echo "Most common fix: restart your container runtime (OrbStack or Docker Desktop) and wait 30 seconds."
    exit 1
else
    echo "Everything looks good!"
fi
