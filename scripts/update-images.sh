#!/bin/bash
# Updates pinned image digests for selected services with approval + rollback safety.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ASSUME_YES=false
SERVICES_SELECTOR="running"
PROFILES=(autoupdate jellyfin)
SELECTED_COUNT=0

usage() {
    cat <<EOF
Usage: bash scripts/update-images.sh [OPTIONS]

Refreshes pinned image digests for selected services, shows a review report,
asks for approval, deploys, health-checks, auto-rolls back on failure, and
auto-commits lock updates on success.

Options:
  --yes             Skip approval prompt
  --services VALUE  Service scope: running | all | svc1,svc2,...
                    Default: running
  --help            Show this help message
EOF
}

log() { echo -e "${GREEN}OK${NC}  $1"; }
warn() { echo -e "${YELLOW}WARN${NC}  $1"; }
info() { echo -e "${CYAN}..${NC}  $1"; }
fail() { echo -e "${RED}FAIL${NC}  $1"; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes)
            ASSUME_YES=true
            shift
            ;;
        --services)
            [[ $# -ge 2 ]] || fail "Missing value for --services"
            SERVICES_SELECTOR="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            fail "Unknown option: $1"
            ;;
    esac
done

for cmd in git docker awk sed mktemp date; do
    command -v "$cmd" >/dev/null 2>&1 || fail "Missing required command: $cmd"
done

PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$PROJECT_DIR" ]] || fail "Not inside a git repository"
cd "$PROJECT_DIR"

COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"
LOCK_FILE="$PROJECT_DIR/IMAGE_LOCK.md"
REFRESH_SCRIPT="$PROJECT_DIR/scripts/refresh-image-lock.sh"
HEALTH_CHECK_SCRIPT="$PROJECT_DIR/scripts/health-check.sh"

[[ -f "$COMPOSE_FILE" ]] || fail "Missing compose file: $COMPOSE_FILE"
[[ -f "$LOCK_FILE" ]] || fail "Missing lock file: $LOCK_FILE"
[[ -x "$REFRESH_SCRIPT" ]] || fail "Missing executable script: $REFRESH_SCRIPT"
[[ -x "$HEALTH_CHECK_SCRIPT" ]] || fail "Missing executable script: $HEALTH_CHECK_SCRIPT"

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    fail "Tracked local changes detected. Commit/stash first."
fi

docker info >/dev/null 2>&1 || fail "Docker runtime is not running."

compose() {
    docker compose "${PROFILE_ARGS[@]}" "$@"
}

add_selected_service() {
    local candidate="$1"
    local existing

    if [[ "$SELECTED_COUNT" -gt 0 ]]; then
        for existing in "${SELECTED_SERVICES[@]}"; do
            if [[ "$existing" == "$candidate" ]]; then
                return 0
            fi
        done
    fi

    SELECTED_SERVICES+=("$candidate")
    ((SELECTED_COUNT++))
}

resolve_selected_services() {
    local running_service service_raw service
    local requested=()

    unset SELECTED_SERVICES
    SELECTED_SERVICES=()
    SELECTED_COUNT=0

    case "$SERVICES_SELECTOR" in
        running)
            while IFS= read -r running_service; do
                [[ -n "$running_service" ]] || continue
                if grep -Fxq "$running_service" "$TMP_ALL_SERVICES"; then
                    add_selected_service "$running_service"
                fi
            done < <(compose ps --services --status running 2>/dev/null || true)
            if [[ "$SELECTED_COUNT" -eq 0 ]]; then
                fail "No running services found for --services=running"
            fi
            ;;
        all)
            while IFS= read -r service; do
                [[ -n "$service" ]] || continue
                add_selected_service "$service"
            done < "$TMP_ALL_SERVICES"
            ;;
        *)
            IFS=',' read -r -a requested <<< "$SERVICES_SELECTOR"
            for service_raw in "${requested[@]}"; do
                service="$(printf '%s' "$service_raw" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
                [[ -n "$service" ]] || continue

                if ! grep -Fxq "$service" "$TMP_ALL_SERVICES"; then
                    fail "Unknown service in --services: $service"
                fi
                add_selected_service "$service"
            done
            if [[ "$SELECTED_COUNT" -eq 0 ]]; then
                fail "No valid services selected via --services=$SERVICES_SELECTOR"
            fi
            ;;
    esac
}

short_digest() {
    local digest_ref="$1"
    local digest

    digest="${digest_ref##*@sha256:}"
    if [[ "$digest" == "$digest_ref" ]]; then
        digest="${digest_ref##*sha256:}"
    fi
    printf '%s' "${digest:0:12}"
}

image_source_url() {
    local image_ref="$1"
    local source

    source="$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.source"}}' "$image_ref" 2>/dev/null || true)"
    if [[ -z "$source" || "$source" == "<no value>" ]]; then
        source="$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.url"}}' "$image_ref" 2>/dev/null || true)"
    fi

    if [[ "$source" == "<no value>" ]]; then
        source=""
    fi
    printf '%s' "$source"
}

github_releases_url() {
    local source="$1"
    local normalized
    local repo_path

    normalized="${source#git+}"
    normalized="${normalized%/}"
    normalized="${normalized%.git}"

    repo_path="$(printf '%s' "$normalized" | sed -nE 's#^https://github\.com/([^/]+/[^/]+).*$#\1#p')"
    if [[ -n "$repo_path" ]]; then
        printf 'https://github.com/%s/releases' "$repo_path"
    fi
}

restore_backups() {
    cp "$TMP_COMPOSE_BACKUP" "$COMPOSE_FILE"
    cp "$TMP_LOCK_BACKUP" "$LOCK_FILE"
}

PROFILE_ARGS=()
for profile in "${PROFILES[@]}"; do
    PROFILE_ARGS+=(--profile "$profile")
done

TMP_ALL_SERVICES="$(mktemp)"
TMP_COMPOSE_BACKUP="$(mktemp)"
TMP_LOCK_BACKUP="$(mktemp)"
TMP_CHANGES="$(mktemp)"
TMP_METADATA="$(mktemp)"

cleanup() {
    rm -f "$TMP_ALL_SERVICES" "$TMP_COMPOSE_BACKUP" "$TMP_LOCK_BACKUP" "$TMP_CHANGES" "$TMP_METADATA"
}
trap cleanup EXIT

compose config --services > "$TMP_ALL_SERVICES"
if [[ ! -s "$TMP_ALL_SERVICES" ]]; then
    fail "Failed to resolve compose services."
fi

resolve_selected_services

cp "$COMPOSE_FILE" "$TMP_COMPOSE_BACKUP"
cp "$LOCK_FILE" "$TMP_LOCK_BACKUP"

info "Refreshing pinned digests for selector: $SERVICES_SELECTOR"
bash "$REFRESH_SCRIPT" --services "$SERVICES_SELECTOR" --emit-changes "$TMP_CHANGES"

CHANGE_COUNT=0
if [[ -s "$TMP_CHANGES" ]]; then
    CHANGE_COUNT="$(wc -l < "$TMP_CHANGES" | tr -d '[:space:]')"
fi

if [[ "$CHANGE_COUNT" -eq 0 ]]; then
    restore_backups
    log "No digest updates available for selector: $SERVICES_SELECTOR"
    exit 0
fi

echo ""
echo "Proposed image digest updates:"
printf "  %-14s %-14s %-14s\n" "Service" "Old SHA" "New SHA"
printf "  %-14s %-14s %-14s\n" "-------" "-------" "-------"
while IFS='|' read -r service old_digest new_digest repo; do
    [[ -n "$service" ]] || continue
    printf "  %-14s %-14s %-14s\n" "$service" "$(short_digest "$old_digest")" "$(short_digest "$new_digest")"
done < "$TMP_CHANGES"

: > "$TMP_METADATA"
while IFS='|' read -r service _old_digest new_digest _repo; do
    [[ -n "$service" ]] || continue
    source_url="$(image_source_url "$new_digest")"
    release_url=""
    if [[ -n "$source_url" ]]; then
        release_url="$(github_releases_url "$source_url" || true)"
        echo "$service|$source_url|$release_url" >> "$TMP_METADATA"
    fi
done < "$TMP_CHANGES"

if [[ -s "$TMP_METADATA" ]]; then
    echo ""
    echo "Image source links:"
    while IFS='|' read -r service source_url release_url; do
        [[ -n "$service" ]] || continue
        echo "  - $service source: $source_url"
        if [[ -n "$release_url" ]]; then
            echo "    changelog: $release_url"
        fi
    done < "$TMP_METADATA"
fi

echo ""
echo "Proposed file diff:"
git --no-pager diff -- "$COMPOSE_FILE" "$LOCK_FILE" || true

if [[ "$ASSUME_YES" != true ]]; then
    echo ""
    read -r -p "Approve image update? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        restore_backups
        log "Update cancelled. Restored previous lock files."
        exit 0
    fi
fi

info "Deploying refreshed images..."
if ! compose up -d "${SELECTED_SERVICES[@]}"; then
    warn "Deployment failed. Rolling back to previous digests..."
    restore_backups
    if ! compose up -d "${SELECTED_SERVICES[@]}"; then
        fail "Rollback deploy failed. Manual intervention required."
    fi
    if bash "$HEALTH_CHECK_SCRIPT"; then
        fail "Update failed. Rollback succeeded and stack health recovered."
    else
        fail "Update failed. Rollback attempted, but health-check still failing."
    fi
fi

if ! bash "$HEALTH_CHECK_SCRIPT"; then
    warn "Health-check failed after deploy. Rolling back to previous digests..."
    restore_backups
    if ! compose up -d "${SELECTED_SERVICES[@]}"; then
        fail "Rollback deploy failed. Manual intervention required."
    fi
    if bash "$HEALTH_CHECK_SCRIPT"; then
        fail "Update failed health-check. Rollback succeeded and stack health recovered."
    else
        fail "Update failed health-check. Rollback attempted, but stack is still unhealthy."
    fi
fi

git add "$COMPOSE_FILE" "$LOCK_FILE"
if git diff --cached --quiet; then
    log "No tracked file changes to commit after deploy."
    exit 0
fi

commit_scope="$SERVICES_SELECTOR"
if [[ "$commit_scope" != "running" && "$commit_scope" != "all" ]]; then
    commit_scope="custom"
fi
commit_date="$(date +%F)"
commit_message="chore(images): refresh ${commit_scope} digests (${commit_date})"
git commit -m "$commit_message" >/dev/null

commit_sha="$(git rev-parse --short HEAD)"
log "Image update committed: $commit_sha"
echo "Committed files:"
echo "  - docker-compose.yml"
echo "  - IMAGE_LOCK.md"
