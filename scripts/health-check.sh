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
# shellcheck source=scripts/lib/media-path.sh
source "$SCRIPT_DIR/scripts/lib/media-path.sh"

MEDIA_DIR="$(resolve_media_dir "$SCRIPT_DIR")"
MEDIA_MOUNT_REASON="$(media_mount_reason "$SCRIPT_DIR")"
MEDIA_READY=false
if media_mount_ready "$SCRIPT_DIR"; then
    MEDIA_READY=true
fi

if [[ -f "$SCRIPT_DIR/.env" ]]; then
    MEDIA_SERVER=$(sed -n 's/^MEDIA_SERVER=//p' "$SCRIPT_DIR/.env" | head -1)
    VPN_PROVIDER=$(sed -n 's/^VPN_PROVIDER=//p' "$SCRIPT_DIR/.env" | head -1)
fi
MEDIA_SERVER="${MEDIA_SERVER:-plex}"
VPN_PROVIDER="${VPN_PROVIDER:-protonvpn}"

read -r -a MOUNT_DEPENDENT_SERVICES <<< "$(mount_dependent_services "$SCRIPT_DIR")"
read -r -a MOUNT_INDEPENDENT_SERVICES <<< "$(mount_independent_services "$SCRIPT_DIR")"

echo ""
echo "=============================="
echo "  Media Stack Health Check"
echo "=============================="
echo ""

PASS=0
FAIL=0

ok() {
    echo -e "  ${GREEN}OK${NC}  $1"
    ((PASS++))
}

fail() {
    echo -e "  ${RED}FAIL${NC}  $1"
    ((FAIL++))
}

skip() {
    echo -e "  ${YELLOW}SKIP${NC}  $1"
}

paused() {
    echo -e "  ${YELLOW}PAUSED${NC}  $1"
}

check_service() {
    local name="$1"
    local url="$2"
    local expected="${3:-200}"
    local status

    status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null)
    if [[ "$status" == "$expected" || "$status" == "301" || "$status" == "302" || "$status" == "307" || "$status" == "308" ]]; then
        ok "$name"
    else
        fail "$name (got HTTP $status)"
    fi
}

container_state() {
    local name="$1"
    docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || true
}

get_netns_id() {
    local name="$1"
    docker exec "$name" sh -lc 'readlink /proc/1/ns/net 2>/dev/null || true' 2>/dev/null \
        | awk -F'[][]' '/^net:\[[0-9]+\]$/ {print $2; exit}'
}

container_http_ok() {
    local name="$1"
    local url="$2"
    local code

    code=$(docker exec "$name" sh -lc "curl -s -o /dev/null -w '%{http_code}' --max-time 5 '$url' 2>/dev/null || true" 2>/dev/null)
    [[ "$code" =~ ^(200|301|302|307|308|401|403)$ ]]
}

mount_reason_text() {
    case "$MEDIA_MOUNT_REASON" in
        missing_mount) echo "Media mount unavailable: $MEDIA_DIR" ;;
        missing_subdirs) echo "Media mount missing required directories under $MEDIA_DIR" ;;
        local_path_missing) echo "Local media path missing: $MEDIA_DIR" ;;
        *) echo "Media path unavailable: $MEDIA_DIR" ;;
    esac
}

RUNTIME=$(detect_installed_runtime)

if docker info &>/dev/null; then
    RUNTIME=$(detect_running_runtime)
    ok "$RUNTIME"
else
    fail "$RUNTIME (not running)"
    echo ""
    echo "Start $RUNTIME and try again."
    exit 1
fi

echo ""
echo "Media Path:"
if [[ "$MEDIA_READY" == true ]]; then
    ok "Media mount ready: $MEDIA_DIR"
else
    fail "$(mount_reason_text)"
fi

echo ""
echo "Containers:"
for name in "${MOUNT_INDEPENDENT_SERVICES[@]}"; do
    state="$(container_state "$name")"
    if [[ "$state" == "running" ]]; then
        ok "$name"
    else
        fail "$name (${state:-not found})"
    fi
done

for name in "${MOUNT_DEPENDENT_SERVICES[@]}"; do
    state="$(container_state "$name")"
    if [[ "$MEDIA_READY" != true && "$state" != "running" ]]; then
        paused "$name (MEDIA_DIR unavailable)"
        continue
    fi

    if [[ "$state" == "running" ]]; then
        ok "$name"
    else
        fail "$name (${state:-not found})"
    fi
done

watchtower_state=$(container_state watchtower)
if [[ "$watchtower_state" == "running" ]]; then
    ok "watchtower (autoupdate profile enabled)"
else
    skip "watchtower (optional; enable with --profile autoupdate)"
fi

echo ""
echo "Web UIs:"
if [[ "$MEDIA_READY" == true ]]; then
    check_service "qBittorrent" "http://localhost:8080"
    check_service "Sonarr" "http://localhost:8989"
    check_service "Radarr" "http://localhost:7878"
    check_service "Bazarr" "http://localhost:6767"
else
    paused "qBittorrent (MEDIA_DIR unavailable)"
    paused "Sonarr (MEDIA_DIR unavailable)"
    paused "Radarr (MEDIA_DIR unavailable)"
    paused "Bazarr (MEDIA_DIR unavailable)"
fi
check_service "Prowlarr" "http://localhost:9696"
check_service "Seerr" "http://localhost:5055"

echo ""
echo "VPN:"
echo "  Provider: $VPN_PROVIDER"
vpn_ip=$(docker exec gluetun sh -lc 'cat /tmp/gluetun/ip 2>/dev/null || true' 2>/dev/null)
vpn_iface=$(docker exec gluetun sh -lc 'ls /sys/class/net 2>/dev/null | grep -E "^(tun|wg)[0-9]+$" | head -1' 2>/dev/null)
vpn_health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}unknown{{end}}' gluetun 2>/dev/null || true)
if [[ -n "$vpn_ip" && -n "$vpn_iface" && "$vpn_health" != "unhealthy" ]]; then
    ok "VPN active (IP: $vpn_ip, iface: $vpn_iface, health: ${vpn_health:-unknown})"
elif [[ -z "$vpn_ip" ]]; then
    fail "VPN not connected (missing /tmp/gluetun/ip)"
elif [[ -z "$vpn_iface" ]]; then
    fail "VPN tunnel interface not detected in gluetun"
else
    fail "VPN health is unhealthy"
fi

if [[ "$MEDIA_READY" == true ]]; then
    gluetun_netns="$(get_netns_id gluetun)"
    qbittorrent_netns="$(get_netns_id qbittorrent)"
    if [[ -n "$gluetun_netns" && -n "$qbittorrent_netns" ]]; then
        if [[ "$gluetun_netns" == "$qbittorrent_netns" ]]; then
            ok "qBittorrent shares gluetun network namespace ($gluetun_netns)"
        else
            fail "qBittorrent network namespace drift (gluetun=$gluetun_netns, qbittorrent=$qbittorrent_netns)"
            echo "       Run: docker restart qbittorrent"
        fi
    else
        skip "Could not verify qBittorrent/gluetun namespace IDs"
    fi

    for arr in radarr sonarr; do
        if [[ "$(container_state "$arr")" != "running" ]]; then
            continue
        fi

        if container_http_ok "$arr" "http://gluetun:8080"; then
            ok "$arr can reach qBittorrent via gluetun:8080"
        else
            fail "$arr cannot reach qBittorrent via gluetun:8080"
        fi
    done
else
    paused "qBittorrent namespace checks (MEDIA_DIR unavailable)"
    paused "Arr to qBittorrent connectivity checks (MEDIA_DIR unavailable)"
fi

echo ""
if [[ "$MEDIA_SERVER" == "jellyfin" ]]; then
    echo "Jellyfin:"
    if [[ "$MEDIA_READY" != true ]]; then
        paused "Jellyfin (MEDIA_DIR unavailable)"
    else
        jf_status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://localhost:8096/health" 2>/dev/null)
        if [[ "$jf_status" == "200" ]]; then
            ok "Jellyfin (http://localhost:8096)"
        else
            fail "Jellyfin not reachable yet (got HTTP ${jf_status:-000})"
        fi
    fi
else
    echo "Plex:"
    plex_status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://localhost:32400/web" 2>/dev/null)
    if [[ "$plex_status" == "200" || "$plex_status" == "302" || "$plex_status" == "301" ]]; then
        ok "Plex (http://localhost:32400/web)"
    else
        skip "Plex not detected (install separately, see SETUP.md)"
    fi
fi

echo ""
echo "=============================="
echo -e "  Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
echo "=============================="
echo ""

if [[ $FAIL -gt 0 ]]; then
    echo "Something's not right. Check the FAIL items above."
    if [[ "$MEDIA_READY" != true ]]; then
        echo "Mount $MEDIA_DIR, then run: docker compose up -d qbittorrent sonarr radarr bazarr"
    else
        echo "Most common fix: restart your container runtime (OrbStack or Docker Desktop) and wait 30 seconds."
    fi
    exit 1
else
    echo "Everything looks good!"
fi
