#!/bin/bash
# Media Stack Auto-Healer
# Runs every few minutes via launchd and heals VPN/container/mount drift.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/lib/media-path.sh
source "$SCRIPT_DIR/lib/media-path.sh"

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

MEDIA_DIR="$(resolve_media_dir "$PROJECT_DIR")"
MEDIA_MOUNT_REASON="$(media_mount_reason "$PROJECT_DIR")"
MEDIA_READY=false
if media_mount_ready "$PROJECT_DIR"; then
    MEDIA_READY=true
fi

LOCAL_FALLBACK_LOG_DIR="$HOME/Library/Logs/media-stack"
ALERT_STATE_DIR="$HOME/Library/Application Support/media-stack/alerts"
ALERT_STATE_FILE="$ALERT_STATE_DIR/incident-state"
ALERT_THRESHOLD_SECONDS=900

read -r -a MOUNT_DEPENDENT_SERVICES <<< "$(mount_dependent_services "$PROJECT_DIR")"
read -r -a MOUNT_INDEPENDENT_SERVICES <<< "$(mount_independent_services "$PROJECT_DIR")"

if [[ "$MEDIA_READY" == true ]]; then
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
PAUSED_SERVICES=()
DEGRADED_SERVICES=()
HEALED=0
FAILED=0
GLUETUN_RESTARTED=0

timestamp() { date "+%Y-%m-%d %H:%M:%S"; }

log() { echo "$(timestamp) $1" >> "$LOG"; }

container_exists() {
    local name="$1"
    docker inspect "$name" >/dev/null 2>&1
}

container_state() {
    local name="$1"
    docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || true
}

container_health() {
    local name="$1"
    docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$name" 2>/dev/null || true
}

array_contains() {
    local needle="$1"
    shift
    local item
    for item in "$@"; do
        if [[ "$item" == "$needle" ]]; then
            return 0
        fi
    done
    return 1
}

is_mount_dependent() {
    local name="$1"
    array_contains "$name" "${MOUNT_DEPENDENT_SERVICES[@]}"
}

compose_up_service() {
    local name="$1"
    if [[ "$name" == "jellyfin" ]]; then
        "${COMPOSE_CMD[@]}" --profile jellyfin up -d "$name"
    elif [[ "$name" == "watchtower" ]]; then
        "${COMPOSE_CMD[@]}" --profile autoupdate up -d "$name"
    else
        "${COMPOSE_CMD[@]}" up -d "$name"
    fi
}

get_netns_id() {
    local name="$1"
    docker exec "$name" sh -lc 'readlink /proc/1/ns/net 2>/dev/null || true' 2>/dev/null \
        | awk -F'[][]' '/^net:\[[0-9]+\]$/ {print $2; exit}'
}

is_http_ok() {
    local url="$1"
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null || true)
    [[ "$code" =~ ^(200|301|302|307|308|401|403)$ ]]
}

container_http_ok() {
    local name="$1"
    local url="$2"
    local code

    code=$(docker exec "$name" sh -lc "curl -s -o /dev/null -w '%{http_code}' --max-time 5 '$url' 2>/dev/null || true" 2>/dev/null)
    [[ "$code" =~ ^(200|301|302|307|308|401|403)$ ]]
}

record_paused_service() {
    local name="$1"
    if ! array_contains "$name" "${PAUSED_SERVICES[@]}"; then
        PAUSED_SERVICES+=("$name")
    fi
}

record_degraded_service() {
    local name="$1"
    if ! array_contains "$name" "${DEGRADED_SERVICES[@]}"; then
        DEGRADED_SERVICES+=("$name")
    fi
}

recreate_service() {
    local name="$1"

    if is_mount_dependent "$name" && [[ "$MEDIA_READY" != true ]]; then
        log "WARN: Skipping recreate for $name because media mount is not ready"
        record_paused_service "$name"
        return 1
    fi

    log "WARN: Recreating $name..."
    if [[ "$name" == "jellyfin" ]]; then
        "${COMPOSE_CMD[@]}" --profile jellyfin up -d --force-recreate --no-deps "$name" >> "$LOG" 2>&1
    elif [[ "$name" == "watchtower" ]]; then
        "${COMPOSE_CMD[@]}" --profile autoupdate up -d --force-recreate --no-deps "$name" >> "$LOG" 2>&1
    else
        "${COMPOSE_CMD[@]}" up -d --force-recreate --no-deps "$name" >> "$LOG" 2>&1
    fi
    if [[ $? -eq 0 ]]; then
        log "OK: Recreated $name"
        ((HEALED++))
        return 0
    fi

    log "ERROR: Failed to recreate $name"
    ((FAILED++))
    record_degraded_service "$name"
    return 1
}

start_service() {
    local name="$1"

    if is_mount_dependent "$name" && [[ "$MEDIA_READY" != true ]]; then
        log "WARN: Skipping start for $name because media mount is not ready"
        record_paused_service "$name"
        return 1
    fi

    log "WARN: Starting $name..."
    if container_exists "$name"; then
        if docker start "$name" >> "$LOG" 2>&1; then
            log "OK: Started $name"
            ((HEALED++))
            return 0
        fi
    else
        if compose_up_service "$name" >> "$LOG" 2>&1; then
            log "OK: Created and started $name"
            ((HEALED++))
            return 0
        fi
    fi

    log "ERROR: Failed to start $name"
    ((FAILED++))
    record_degraded_service "$name"
    return 1
}

restart_service() {
    local name="$1"

    if is_mount_dependent "$name" && [[ "$MEDIA_READY" != true ]]; then
        log "WARN: Skipping restart for $name because media mount is not ready"
        record_paused_service "$name"
        return 1
    fi

    log "WARN: Restarting $name..."
    if docker restart "$name" >> "$LOG" 2>&1; then
        log "OK: Restarted $name"
        ((HEALED++))
        return 0
    fi

    log "ERROR: Failed to restart $name"
    ((FAILED++))
    record_degraded_service "$name"
    return 1
}

stop_service() {
    local name="$1"
    if [[ "$(container_state "$name")" != "running" ]]; then
        return 0
    fi

    log "WARN: Stopping $name because media mount is not ready"
    if docker stop "$name" >> "$LOG" 2>&1; then
        log "OK: Stopped $name"
        ((HEALED++))
        record_paused_service "$name"
        return 0
    fi

    log "ERROR: Failed to stop $name"
    ((FAILED++))
    record_degraded_service "$name"
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

    if [[ -z "$missing" ]]; then
        return 0
    fi

    if [[ "$MEDIA_READY" == true ]]; then
        log "WARN: $service missing expected mount path(s):$missing"
        recreate_service "$service"
    else
        log "WARN: $service missing expected mount path(s):$missing while media mount is unavailable"
        stop_service "$service"
    fi
}

wait_for_qbittorrent() {
    local attempts="${1:-15}"
    local attempt=0

    while [[ $attempt -lt $attempts ]]; do
        if is_http_ok "http://localhost:8080" && docker exec gluetun sh -lc 'wget -q --spider --timeout=5 http://127.0.0.1:8080' >/dev/null 2>&1; then
            log "OK: qBittorrent reachable from host and gluetun namespace"
            return 0
        fi
        sleep 2
        attempt=$((attempt + 1))
    done

    log "ERROR: qBittorrent is still not reachable after waiting"
    ((FAILED++))
    record_degraded_service "qbittorrent"
    return 1
}

format_duration() {
    local total_seconds="$1"
    local hours minutes seconds

    hours=$((total_seconds / 3600))
    minutes=$(((total_seconds % 3600) / 60))
    seconds=$((total_seconds % 60))

    if [[ $hours -gt 0 ]]; then
        printf '%dh %dm %ds' "$hours" "$minutes" "$seconds"
    elif [[ $minutes -gt 0 ]]; then
        printf '%dm %ds' "$minutes" "$seconds"
    else
        printf '%ds' "$seconds"
    fi
}

escape_osascript_string() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '%s\n' "$value"
}

send_notification() {
    local title="$1"
    local body="$2"
    local escaped_title escaped_body

    if ! command -v osascript >/dev/null 2>&1; then
        log "WARN: osascript not available; skipping notification"
        return 1
    fi

    escaped_title="$(escape_osascript_string "$title")"
    escaped_body="$(escape_osascript_string "$body")"

    if osascript -e "display notification \"$escaped_body\" with title \"$escaped_title\"" >/dev/null 2>&1; then
        log "OK: Sent notification: $title"
        return 0
    fi

    log "WARN: Failed to send notification: $title"
    return 1
}

save_incident_state() {
    mkdir -p "$ALERT_STATE_DIR"
    cat > "$ALERT_STATE_FILE" <<EOF
incident_id=$(printf '%q' "$INCIDENT_ID")
cause=$(printf '%q' "$INCIDENT_CAUSE")
first_seen_epoch=$(printf '%q' "$INCIDENT_FIRST_SEEN")
last_alert_epoch=$(printf '%q' "$INCIDENT_LAST_ALERT")
status=$(printf '%q' "$INCIDENT_STATUS")
affected_services=$(printf '%q' "$INCIDENT_AFFECTED")
media_dir=$(printf '%q' "$MEDIA_DIR")
EOF
}

load_incident_state() {
    INCIDENT_ID=""
    INCIDENT_CAUSE=""
    INCIDENT_FIRST_SEEN=""
    INCIDENT_LAST_ALERT="0"
    INCIDENT_STATUS=""
    INCIDENT_AFFECTED=""
    INCIDENT_MEDIA_DIR=""

    if [[ -f "$ALERT_STATE_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$ALERT_STATE_FILE"
        INCIDENT_ID="${incident_id:-}"
        INCIDENT_CAUSE="${cause:-}"
        INCIDENT_FIRST_SEEN="${first_seen_epoch:-}"
        INCIDENT_LAST_ALERT="${last_alert_epoch:-0}"
        INCIDENT_STATUS="${status:-}"
        INCIDENT_AFFECTED="${affected_services:-}"
        INCIDENT_MEDIA_DIR="${media_dir:-}"
    fi
}

clear_incident_state() {
    rm -f "$ALERT_STATE_FILE"
}

incident_summary_text() {
    local cause="$1"
    case "$cause" in
        media_mount_missing_mount) echo "media mount is missing" ;;
        media_mount_missing_subdirs) echo "media mount is missing required subdirectories" ;;
        media_mount_local_path_missing) echo "local media path is missing" ;;
        services_down) echo "services are still down after recovery attempts" ;;
        *) echo "$cause" ;;
    esac
}

handle_alert_state() {
    local active_cause="$1"
    local affected_services="$2"
    local now duration summary

    load_incident_state
    now="$(date +%s)"

    if [[ -z "$active_cause" || -z "$affected_services" ]]; then
        if [[ "$INCIDENT_STATUS" == "active" ]]; then
            duration=$((now - INCIDENT_FIRST_SEEN))
            if [[ "${INCIDENT_LAST_ALERT:-0}" -gt 0 ]]; then
                send_notification \
                    "Media Stack Recovered" \
                    "Recovered after $(format_duration "$duration"): ${INCIDENT_AFFECTED}"
            fi
            clear_incident_state
            log "OK: Cleared active incident state"
        fi
        return 0
    fi

    summary="$(incident_summary_text "$active_cause")"
    if [[ "$INCIDENT_ID" != "$active_cause|$affected_services|$MEDIA_DIR" || "$INCIDENT_STATUS" != "active" ]]; then
        INCIDENT_ID="$active_cause|$affected_services|$MEDIA_DIR"
        INCIDENT_CAUSE="$active_cause"
        INCIDENT_FIRST_SEEN="$now"
        INCIDENT_LAST_ALERT="0"
        INCIDENT_STATUS="active"
        INCIDENT_AFFECTED="$affected_services"
        save_incident_state
        log "WARN: Opened incident: $summary ($affected_services)"
        return 0
    fi

    duration=$((now - INCIDENT_FIRST_SEEN))
    if [[ "${INCIDENT_LAST_ALERT:-0}" -eq 0 && $duration -ge $ALERT_THRESHOLD_SECONDS ]]; then
        if send_notification \
            "Media Stack Services Still Down" \
            "Cause: $summary. Duration: $(format_duration "$duration"). Services: $affected_services. Media path: $MEDIA_DIR"; then
            INCIDENT_LAST_ALERT="$now"
            save_incident_state
        fi
    fi
}

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

if [[ "$MEDIA_READY" == true ]]; then
    log "OK: Media mount ready at $MEDIA_DIR"
else
    log "WARN: Media mount not ready at $MEDIA_DIR (reason=${MEDIA_MOUNT_REASON:-unknown})"
fi

if [[ "$(container_state gluetun)" != "running" ]]; then
    start_service gluetun
    if [[ "$(container_state gluetun)" == "running" ]]; then
        sleep 8
    fi
fi

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
    record_degraded_service "gluetun"
fi

if [[ $GLUETUN_RESTARTED -eq 1 ]]; then
    if [[ "$MEDIA_READY" == true ]]; then
        log "INFO: Recreating qbittorrent after gluetun restart to reattach network/mounts"
        recreate_service qbittorrent
        sleep 8
    else
        log "WARN: Skipping qBittorrent recreate after gluetun restart because media mount is not ready"
        record_paused_service "qbittorrent"
    fi
fi

for service in "${MOUNT_INDEPENDENT_SERVICES[@]}"; do
    state="$(container_state "$service")"
    health="$(container_health "$service")"

    if [[ -z "$state" ]]; then
        log "WARN: Container not found: $service"
        ((FAILED++))
        record_degraded_service "$service"
        continue
    fi

    if [[ "$state" != "running" ]]; then
        start_service "$service"
        continue
    fi

    if [[ "$health" == "unhealthy" ]]; then
        restart_service "$service"
    fi
done

if [[ "$MEDIA_READY" == true ]]; then
    for service in qbittorrent sonarr radarr bazarr jellyfin; do
        if ! is_mount_dependent "$service"; then
            continue
        fi

        if [[ "$(container_state "$service")" != "running" ]]; then
            start_service "$service"
        fi

        if [[ "$service" == "qbittorrent" ]]; then
            if [[ "$(container_state "$service")" != "running" ]] || ! wait_for_qbittorrent; then
                break
            fi
        fi
    done
else
    for service in "${MOUNT_DEPENDENT_SERVICES[@]}"; do
        if [[ "$(container_state "$service")" != "running" ]]; then
            record_paused_service "$service"
        fi
    done
fi

gluetun_netns="$(get_netns_id gluetun)"
qbittorrent_netns="$(get_netns_id qbittorrent)"
if [[ "$MEDIA_READY" == true ]]; then
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
                record_degraded_service "qbittorrent"
            fi
        else
            log "OK: qBittorrent network namespace matches gluetun ($gluetun_netns)"
        fi
    else
        log "WARN: Could not read network namespace IDs for gluetun/qbittorrent"
    fi

    if [[ "$(container_state qbittorrent)" == "running" ]] && \
       (! is_http_ok "http://localhost:8080" || ! docker exec gluetun sh -lc 'wget -q --spider --timeout=5 http://127.0.0.1:8080' >/dev/null 2>&1); then
        log "WARN: qBittorrent not reachable from host or gluetun namespace"
        recreate_service qbittorrent
        sleep 8
        wait_for_qbittorrent
    fi
else
    log "WARN: Skipping qBittorrent namespace and HTTP checks because media mount is not ready"
fi

for arr in radarr sonarr; do
    if [[ "$(container_state "$arr")" != "running" ]]; then
        continue
    fi

    if container_http_ok "$arr" "http://gluetun:8080"; then
        log "OK: $arr can reach qBittorrent via gluetun:8080"
    else
        if [[ "$MEDIA_READY" == true ]]; then
            log "WARN: $arr cannot reach qBittorrent via gluetun:8080"
            restart_service "$arr"
            sleep 5
        else
            log "WARN: $arr cannot reach qBittorrent and media mount is not ready"
            stop_service "$arr"
        fi
    fi
done

for service in "${MOUNT_DEPENDENT_SERVICES[@]}"; do
    check_service_mounts "$service"
done

if [[ "$MEDIA_READY" == true ]]; then
    for service in "${MOUNT_DEPENDENT_SERVICES[@]}"; do
        state="$(container_state "$service")"
        health="$(container_health "$service")"

        if [[ -z "$state" ]]; then
            log "WARN: Container not found: $service"
            ((FAILED++))
            record_degraded_service "$service"
            continue
        fi

        if [[ "$state" != "running" ]]; then
            record_degraded_service "$service"
            continue
        fi

        if [[ "$health" == "unhealthy" ]]; then
            if [[ "$service" == "qbittorrent" || "$service" == "sonarr" || "$service" == "radarr" || "$service" == "bazarr" || "$service" == "jellyfin" ]]; then
                recreate_service "$service"
            else
                restart_service "$service"
            fi
        fi
    done
else
    for service in "${MOUNT_DEPENDENT_SERVICES[@]}"; do
        if [[ "$(container_state "$service")" != "running" ]]; then
            record_paused_service "$service"
        fi
    done
fi

if [[ "${#PAUSED_SERVICES[@]}" -gt 0 ]]; then
    log "WARN: Media mount not ready at $MEDIA_DIR; paused services: ${PAUSED_SERVICES[*]}"
fi

ACTIVE_ALERT_CAUSE=""
ACTIVE_ALERT_SERVICES=""
DEPENDENT_DEGRADED_SERVICES=()
for service in "${DEGRADED_SERVICES[@]}"; do
    if is_mount_dependent "$service"; then
        DEPENDENT_DEGRADED_SERVICES+=("$service")
    fi
done
if [[ "$MEDIA_READY" != true && "${#PAUSED_SERVICES[@]}" -gt 0 ]]; then
    ACTIVE_ALERT_CAUSE="media_mount_${MEDIA_MOUNT_REASON:-unknown}"
    ACTIVE_ALERT_SERVICES="${PAUSED_SERVICES[*]}"
elif [[ "${#DEPENDENT_DEGRADED_SERVICES[@]}" -gt 0 ]]; then
    ACTIVE_ALERT_CAUSE="services_down"
    ACTIVE_ALERT_SERVICES="${DEPENDENT_DEGRADED_SERVICES[*]}"
fi
handle_alert_state "$ACTIVE_ALERT_CAUSE" "$ACTIVE_ALERT_SERVICES"

if [[ $HEALED -gt 0 ]]; then
    log "Healed $HEALED issue(s)"
fi

if [[ $FAILED -gt 0 ]]; then
    log "Finished with $FAILED unresolved issue(s)"
    exit 1
fi

if [[ "${#PAUSED_SERVICES[@]}" -gt 0 ]]; then
    log "Finished with ${#PAUSED_SERVICES[@]} paused service(s)"
    exit 1
fi

log "All healthy"
