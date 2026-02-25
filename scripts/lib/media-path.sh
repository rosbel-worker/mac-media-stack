#!/bin/bash
# Shared path resolvers.
# Priority: explicit env var -> .env value -> default.

resolve_path_from_env_file() {
    local key="$1"
    local default_value="$2"
    local project_dir="${3:-}"
    local env_file value

    if [[ -z "$project_dir" ]]; then
        project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    fi

    env_file="$project_dir/.env"
    value="${!key:-}"

    if [[ -z "$value" && -f "$env_file" ]]; then
        value="$(sed -n "s/^${key}=//p" "$env_file" | head -1)"
    fi

    value="${value%\"}"
    value="${value#\"}"
    value="${value%\'}"
    value="${value#\'}"
    value="${value:-$default_value}"
    value="${value/#\~/$HOME}"

    printf '%s\n' "$value"
}

resolve_media_dir() {
    local project_dir="${1:-}"
    resolve_path_from_env_file "MEDIA_DIR" "$HOME/Media" "$project_dir"
}

resolve_config_dir() {
    local project_dir="${1:-}"
    resolve_path_from_env_file "CONFIG_DIR" "$HOME/home-media-stack/config" "$project_dir"
}
