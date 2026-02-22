#!/bin/bash
# Refreshes image digests in docker-compose.yml and regenerates IMAGE_LOCK.md.
# Uses :latest for each configured image repository, then pins by digest.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
LOCK_FILE="$SCRIPT_DIR/IMAGE_LOCK.md"
ENV_FILE="$SCRIPT_DIR/.env"

PROFILES=(autoupdate)
OPTIONAL_SERVICES=(watchtower)

for cmd in docker awk sed mktemp; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Missing required command: $cmd"
        exit 1
    fi
done

if [[ ! -f "$COMPOSE_FILE" ]]; then
    echo "Could not find $COMPOSE_FILE"
    exit 1
fi

compose() {
    docker compose "${PROFILE_ARGS[@]}" "$@"
}

PROFILE_ARGS=()
for profile in "${PROFILES[@]}"; do
    PROFILE_ARGS+=(--profile "$profile")
done

tmp_map="$(mktemp)"
tmp_compose="$(mktemp)"
tmp_rendered="$(mktemp)"

cleanup() {
    if [[ "${CREATED_ENV:-0}" == "1" ]]; then
        rm -f "$ENV_FILE"
    fi
    rm -f "$tmp_map" "$tmp_compose" "$tmp_rendered"
}
trap cleanup EXIT

CREATED_ENV=0
if [[ ! -f "$ENV_FILE" ]]; then
    cp "$SCRIPT_DIR/.env.example" "$ENV_FILE"
    CREATED_ENV=1
fi

compose config > "$tmp_rendered"
while IFS= read -r service; do
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
        echo "Could not resolve image for service: $service"
        exit 1
    fi
    echo "$service|$image_ref" >> "$tmp_map"
done < <(compose config --services)

if [[ ! -s "$tmp_map" ]]; then
    echo "Failed to parse service images from compose config."
    exit 1
fi

while IFS='|' read -r service image_ref; do
    repo="${image_ref%@*}"
    candidate="${repo}:latest"
    echo "Refreshing $service ($candidate)"
    docker pull "$candidate" >/dev/null
    digest="$(docker image inspect --format '{{index .RepoDigests 0}}' "$candidate")"
    if [[ -z "$digest" ]]; then
        echo "Failed to resolve digest for $candidate"
        exit 1
    fi
    sed -i '' -E "s#^${service}\\|.*#${service}|${digest}#" "$tmp_map"
done < "$tmp_map"

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
    echo "bash scripts/refresh-image-lock.sh"
    echo "\`\`\`"
    echo
    echo "Then smoke test the stack and commit the updated lock files."
} > "$LOCK_FILE"

echo "Updated:"
echo "  - $COMPOSE_FILE"
echo "  - $LOCK_FILE"
