#!/bin/bash
# Refreshes image digests in docker-compose.yml and regenerates IMAGE_LOCK.md.
# Uses :latest for each configured image repository, then pins by digest.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
LOCK_FILE="$SCRIPT_DIR/IMAGE_LOCK.md"
ENV_FILE="$SCRIPT_DIR/.env"

PROFILES=(autoupdate jellyfin)
OPTIONAL_SERVICES=(watchtower jellyfin)
SERVICES_SELECTOR="all"
EMIT_CHANGES=""

usage() {
    cat <<EOF
Usage: bash scripts/refresh-image-lock.sh [OPTIONS]

Refreshes image digests in docker-compose.yml and regenerates IMAGE_LOCK.md.

Options:
  --services VALUE   Service scope: all | running | svc1,svc2,...
                     Default: all
  --emit-changes PATH
                     Write changed rows as: service|old_digest|new_digest|repo
  --help             Show this help message
EOF
}

fail() {
    echo "$1"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --services)
            [[ $# -ge 2 ]] || fail "Missing value for --services"
            SERVICES_SELECTOR="$2"
            shift 2
            ;;
        --emit-changes)
            [[ $# -ge 2 ]] || fail "Missing value for --emit-changes"
            EMIT_CHANGES="$2"
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

for cmd in docker awk sed mktemp date; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        fail "Missing required command: $cmd"
    fi
done

if [[ ! -f "$COMPOSE_FILE" ]]; then
    fail "Could not find $COMPOSE_FILE"
fi

compose() {
    docker compose "${PROFILE_ARGS[@]}" "$@"
}

image_repo_from_ref() {
    local ref="$1"
    local repo

    repo="${ref%@*}"
    if [[ "$repo" =~ :[^/:]+$ ]]; then
        repo="${repo%:*}"
    fi

    printf '%s' "$repo"
}

resolve_digest_from_candidate() {
    local candidate="$1"
    local repo="$2"
    local digest

    digest="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$candidate" 2>/dev/null | awk -v repo="$repo" '
        BEGIN { first="" }
        {
            if (first == "") first = $0
            if ($0 ~ ("^" repo "@sha256:")) {
                print $0
                found = 1
                exit
            }
        }
        END {
            if (!found && first != "") print first
        }
    ')"

    printf '%s' "$digest"
}

PROFILE_ARGS=()
for profile in "${PROFILES[@]}"; do
    PROFILE_ARGS+=(--profile "$profile")
done

tmp_map="$(mktemp)"
tmp_compose="$(mktemp)"
tmp_rendered="$(mktemp)"
tmp_services_all="$(mktemp)"
tmp_services_selected="$(mktemp)"
tmp_changes="$(mktemp)"

cleanup() {
    if [[ "${CREATED_ENV:-0}" == "1" ]]; then
        rm -f "$ENV_FILE"
    fi
    rm -f "$tmp_map" "$tmp_compose" "$tmp_rendered" "$tmp_services_all" "$tmp_services_selected" "$tmp_changes"
}
trap cleanup EXIT

CREATED_ENV=0
if [[ ! -f "$ENV_FILE" ]]; then
    cp "$SCRIPT_DIR/.env.example" "$ENV_FILE"
    CREATED_ENV=1
fi

compose config > "$tmp_rendered"
compose config --services > "$tmp_services_all"

if [[ ! -s "$tmp_services_all" ]]; then
    fail "Failed to resolve compose services."
fi

resolve_selected_services() {
    local running_service requested service_raw service

    : > "$tmp_services_selected"

    case "$SERVICES_SELECTOR" in
        all)
            cat "$tmp_services_all" > "$tmp_services_selected"
            ;;
        running)
            while IFS= read -r running_service; do
                [[ -n "$running_service" ]] || continue
                if grep -Fxq "$running_service" "$tmp_services_all"; then
                    echo "$running_service" >> "$tmp_services_selected"
                fi
            done < <(compose ps --services --status running 2>/dev/null || true)
            ;;
        *)
            IFS=',' read -r -a requested <<< "$SERVICES_SELECTOR"
            for service_raw in "${requested[@]}"; do
                service="$(printf '%s' "$service_raw" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
                [[ -n "$service" ]] || continue

                if ! grep -Fxq "$service" "$tmp_services_all"; then
                    fail "Unknown service in --services: $service"
                fi

                if ! grep -Fxq "$service" "$tmp_services_selected" 2>/dev/null; then
                    echo "$service" >> "$tmp_services_selected"
                fi
            done
            ;;
    esac

    if [[ ! -s "$tmp_services_selected" ]]; then
        fail "No services selected with --services=$SERVICES_SELECTOR"
    fi
}

resolve_selected_services

while IFS= read -r service; do
    [[ -n "$service" ]] || continue
    image_ref="$(awk -v svc="$service" '
        $0 ~ ("^  " svc ":$") { in_service=1; next }
        in_service && $0 ~ /^    image:[[:space:]]+/ {
            line=$0
            sub(/^    image:[[:space:]]+/, "", line)
            print line
            exit
        }
        in_service && $0 ~ /^  [A-Za-z0-9_-]+:$/ { in_service=0 }
    ' "$tmp_rendered")"

    if [[ -z "$image_ref" ]]; then
        fail "Could not resolve image for service: $service"
    fi
    echo "$service|$image_ref" >> "$tmp_map"
done < "$tmp_services_all"

if [[ ! -s "$tmp_map" ]]; then
    fail "Failed to parse service images from compose config."
fi

while IFS= read -r service; do
    [[ -n "$service" ]] || continue

    image_ref="$(awk -F'|' -v svc="$service" '$1 == svc { print $2; exit }' "$tmp_map")"
    if [[ -z "$image_ref" ]]; then
        fail "Could not resolve current image digest for service: $service"
    fi

    repo="$(image_repo_from_ref "$image_ref")"
    candidate="${repo}:latest"
    echo "Refreshing $service ($candidate)"
    docker pull "$candidate" >/dev/null

    digest="$(resolve_digest_from_candidate "$candidate" "$repo")"
    if [[ -z "$digest" ]]; then
        fail "Failed to resolve digest for $candidate"
    fi

    if [[ "$image_ref" != "$digest" ]]; then
        echo "$service|$image_ref|$digest|$repo" >> "$tmp_changes"
    fi

    tmp_map_next="$(mktemp)"
    awk -F'|' -v svc="$service" -v dig="$digest" '
        BEGIN { OFS="|" }
        $1 == svc { $2 = dig }
        { print }
    ' "$tmp_map" > "$tmp_map_next"
    mv "$tmp_map_next" "$tmp_map"
done < "$tmp_services_selected"

awk -F'|' '
    NR==FNR { lock[$1]=$2; next }
    /^[ ]{2}[a-zA-Z0-9_-]+:$/ {
        svc=$0
        sub(/^[ ]{2}/, "", svc)
        sub(/:$/, "", svc)
        current=svc
        print
        next
    }
    /^[ ]{4}image:/ && (current in lock) {
        print "    image: " lock[current]
        next
    }
    { print }
' "$tmp_map" "$COMPOSE_FILE" > "$tmp_compose"

mv "$tmp_compose" "$COMPOSE_FILE"

docker_engine="$(docker version --format '{{.Server.Version}}')"
platform="$(docker info --format '{{.Architecture}} ({{.OperatingSystem}})')"
date_utc="$(date -u +%F)"

{
    echo "# Image Lock Matrix"
    echo
    echo "This stack is pinned to exact image digests in \`docker-compose.yml\` for reproducible installs."
    echo
    echo "Tested lock snapshot:"
    echo "- Date: \`$date_utc\`"
    echo "- Docker Engine: \`$docker_engine\`"
    echo "- Platform: \`$platform\`"
    echo
    echo "| Service | Locked Image |"
    echo "|---|---|"
    while IFS='|' read -r service digest; do
        label="$service"
        for optional in "${OPTIONAL_SERVICES[@]}"; do
            if [[ "$service" == "$optional" ]]; then
                label="$service (optional)"
            fi
        done
        echo "| $label | \`$digest\` |"
    done < "$tmp_map"
    echo
    echo "## Updating The Lock"
    echo
    echo "Run:"
    echo "\`\`\`bash"
    echo "bash scripts/refresh-image-lock.sh --services all"
    echo "\`\`\`"
    echo
    echo "Then smoke test the stack and commit the updated lock files."
} > "$LOCK_FILE"

if [[ -n "$EMIT_CHANGES" ]]; then
    cp "$tmp_changes" "$EMIT_CHANGES"
fi

echo "Updated:"
echo "  - $COMPOSE_FILE"
echo "  - $LOCK_FILE"
echo "Service selector: $SERVICES_SELECTOR"
