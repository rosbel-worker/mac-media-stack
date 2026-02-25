#!/bin/bash
# Media Stack Auto-Healer
# Runs every few minutes via launchd and heals VPN/container/mount drift.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/lib/media-path.sh
source "$SCRIPT_DIR/lib/media-path.sh"

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

MEDIA_DIR="$(resolve_media_dir "$PROJECT_DIR")"
LOCAL_FALLBACK_LOG_DIR="$HOME/Library/Logs/media-stack"

media_mount_ready() {
    local media_mount_line

    if [[ "$MEDIA_DIR" == /Volumes/* ]]; then
        media_mount_line="$(mount | grep -F " on $MEDIA_DIR (" || true)"
        [[ -n "$media_mount_line" ]] || return 1
    fi

    [[ -d "$MEDIA_DIR/Downloads" && -d "$MEDIA_DIR/Movies" && -d "$MEDIA_DIR/TV Shows" ]]
}

if media_mount_ready; then
    LOG_DIR="$MEDIA_DIR/logs"
else
    LOG_DIR="$LOCAL_FALLBACK_LOG_DIR"
fi

mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG="$LOG_DIR/auto-heal.log"
if ! { : >> "$LOG"; } 2>/dev/null; then
    LOG_DIR="$LOCAL_FALLBACK_LOG_DIR"
    mkdir -p "$LOG_DIR"
    LOG="$LOG_DIR/auto-heal.log"
    : >> "$LOG" 2>/dev/null || LOG="/tmp/media-stack-auto-heal.log"
fi
COMPOSE_CMD=(docker compose -f "$PROJECT_DIR/docker-compose.yml" --project-directory "$PROJECT_DIR")

timestamp() { date "+%Y-%m-%d %H:%M:%S"; }

log() { echo "$(timestamp) $1" >> "$LOG"; }

get_netns_id() {
    local name="$1"
    docker exec "$name" sh -lc 'readlink /proc/1/ns/net 2>/dev/null || true' 2>/dev/null \
        | awk -F'[][]' '/^net:\[[0-9]+\]$/ {print $2; exit}'
}

container_state() {
    local name="$1"
    docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || true
}

container_health() {
    local name="$1"
    docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$name" 2>/dev/null || true
}

is_http_ok() {
    local url="$1"
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null || true)
    [[ "$code" =~ ^(200|301|302|307|308|401|403)$ ]]
}

recreate_service() {
    local name="$1"
    log "WARN: Recreating $name..."
    if "${COMPOSE_CMD[@]}" up -d --force-recreate --no-deps "$name" >> "$LOG" 2>&1; then
        log "OK: Recreated $name"
        ((HEALED++))
        return 0
    fi

    log "ERROR: Failed to recreate $name"
    ((FAILED++))
    return 1
}

restart_service() {
    local name="$1"
    log "WARN: Restarting $name..."
    if docker restart "$name" >> "$LOG" 2>&1; then
        log "OK: Restarted $name"
        ((HEALED++))
        return 0
    fi

    log "ERROR: Failed to restart $name"
    ((FAILED++))
    return 1
}

expected_mount_paths() {
    local service="$1"
    case "$service" in
        qbittorrent) echo "/downloads /movies /tv" ;;
        sonarr) echo "/downloads /tv" ;;
        radarr) echo "/downloads /movies" ;;
        bazarr) echo "/movies /tv" ;;
        jellyfin) echo "/data/movies /data/tvshows" ;;
        *) echo "" ;;
    esac
}

check_service_mounts() {
    local service="$1"
    local expected missing path

    expected="$(expected_mount_paths "$service")"
    [[ -n "$expected" ]] || return 0

    if [[ "$(container_state "$service")" != "running" ]]; then
        return 0
    fi

    missing=""
    for path in $expected; do
        if ! docker exec "$service" sh -lc "[ -d \"$path\" ]" >/dev/null 2>&1; then
            missing="$missing $path"
        fi
    done

    if [[ -n "$missing" ]]; then
        if media_mount_ready; then
            log "WARN: $service missing expected mount path(s):$missing"
            recreate_service "$service"
        else
            log "WARN: $service missing mount path(s):$missing (media mount not ready yet, skipping recreate)"
        fi
    fi
}

# Trim log to last 800 lines
if [[ -f "$LOG" ]] && [[ $(wc -l < "$LOG") -gt 800 ]]; then
    tail -800 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

log "--- Health check started ---"

if ! command -v docker >/dev/null 2>&1; then
    log "ERROR: docker CLI not found in PATH. Cannot heal."
    exit 1
fi

if ! docker info &>/dev/null; then
    log "ERROR: Container runtime not running. Cannot heal."
    exit 1
fi

HEALED=0
FAILED=0
GLUETUN_RESTARTED=0

# Ensure gluetun is running before VPN checks.
if [[ "$(container_state gluetun)" != "running" ]]; then
    log "WARN: gluetun is not running. Starting..."
    if docker start gluetun >> "$LOG" 2>&1; then
        ((HEALED++))
        sleep 8
    else
        log "ERROR: Failed to start gluetun"
        ((FAILED++))
    fi
fi

# Check VPN tunnel.
vpn_ip=$(docker exec gluetun sh -lc 'cat /tmp/gluetun/ip 2>/dev/null || true' 2>/dev/null)
vpn_iface=$(docker exec gluetun sh -lc 'ls /sys/class/net 2>/dev/null | grep -E "^(tun|wg)[0-9]+$" | head -1' 2>/dev/null)
vpn_health=$(container_health gluetun)

if [[ -z "$vpn_ip" || -z "$vpn_iface" || "$vpn_health" == "unhealthy" ]]; then
    log "WARN: VPN status unhealthy (health=${vpn_health:-unknown}, ip=${vpn_ip:-none}, iface=${vpn_iface:-none})"
    if restart_service gluetun; then
        GLUETUN_RESTARTED=1
        sleep 20
    fi

    vpn_ip=$(docker exec gluetun sh -lc 'cat /tmp/gluetun/ip 2>/dev/null || true' 2>/dev/null)
    vpn_iface=$(docker exec gluetun sh -lc 'ls /sys/class/net 2>/dev/null | grep -E "^(tun|wg)[0-9]+$" | head -1' 2>/dev/null)
    vpn_health=$(container_health gluetun)
fi

if [[ -n "$vpn_ip" && -n "$vpn_iface" && "$vpn_health" != "unhealthy" ]]; then
    log "OK: VPN active (IP: $vpn_ip, iface=$vpn_iface, health=${vpn_health:-unknown})"
else
    log "ERROR: VPN still unhealthy (health=${vpn_health:-unknown}, ip=${vpn_ip:-none}, iface=${vpn_iface:-none})"
    ((FAILED++))
fi

if [[ $GLUETUN_RESTARTED -eq 1 ]]; then
    log "INFO: Recreating qbittorrent after gluetun restart to reattach network/mounts"
    recreate_service qbittorrent
    sleep 8
fi

# Validate qBittorrent is still sharing gluetun network namespace.
gluetun_netns="$(get_netns_id gluetun)"
qbittorrent_netns="$(get_netns_id qbittorrent)"
if [[ -n "$gluetun_netns" && -n "$qbittorrent_netns" ]]; then
    if [[ "$gluetun_netns" != "$qbittorrent_netns" ]]; then
        log "WARN: Network namespace drift detected (gluetun=$gluetun_netns, qbittorrent=$qbittorrent_netns)"
        recreate_service qbittorrent
        sleep 8
        qbittorrent_netns="$(get_netns_id qbittorrent)"
        if [[ "$gluetun_netns" == "$qbittorrent_netns" ]]; then
            log "OK: qBittorrent reattached to gluetun namespace ($qbittorrent_netns)"
        else
            log "ERROR: qBittorrent namespace still mismatched after recreate (gluetun=$gluetun_netns, qbittorrent=${qbittorrent_netns:-unknown})"
            ((FAILED++))
        fi
    else
        log "OK: qBittorrent network namespace matches gluetun ($gluetun_netns)"
    fi
else
    log "WARN: Could not read network namespace IDs for gluetun/qbittorrent"
fi

# Ensure qBittorrent is reachable from host and from gluetun namespace.
if ! is_http_ok "http://localhost:8080" || ! docker exec gluetun sh -lc 'wget -q --spider --timeout=5 http://127.0.0.1:8080' >/dev/null 2>&1; then
    log "WARN: qBittorrent not reachable from host or gluetun namespace"
    recreate_service qbittorrent
    sleep 8
fi

# Core container state/health checks.
for name in gluetun qbittorrent prowlarr sonarr radarr bazarr flaresolverr seerr; do
    state=$(container_state "$name")
    health=$(container_health "$name")

    if [[ -z "$state" ]]; then
        log "WARN: Container not found: $name"
        ((FAILED++))
        continue
    fi

    if [[ "$state" != "running" ]]; then
        log "WARN: $name state=$state, starting..."
        if docker start "$name" >> "$LOG" 2>&1; then
            ((HEALED++))
        else
            log "ERROR: Failed to start $name"
            ((FAILED++))
        fi
        continue
    fi

    if [[ "$health" == "unhealthy" ]]; then
        if [[ "$name" == "qbittorrent" || "$name" == "sonarr" || "$name" == "radarr" || "$name" == "bazarr" ]]; then
            recreate_service "$name"
        else
            restart_service "$name"
        fi
    fi
done

# Repair bind-mount drift (common after macOS sleep/resume).
for name in qbittorrent sonarr radarr bazarr; do
    check_service_mounts "$name"
done

if [[ "$(container_state jellyfin)" == "running" ]]; then
    check_service_mounts jellyfin
fi

if [[ $HEALED -gt 0 ]]; then
    log "Healed $HEALED issue(s)"
else
    log "All healthy"
fi

if [[ $FAILED -gt 0 ]]; then
    log "Finished with $FAILED unresolved issue(s)"
    exit 1
fi
