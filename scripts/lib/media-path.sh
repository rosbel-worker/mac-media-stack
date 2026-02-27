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

get_env_value_from_project() {
    local key="$1"
    local project_dir="${2:-}"
    local env_file

    if [[ -z "$project_dir" ]]; then
        project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    fi

    env_file="$project_dir/.env"
    if [[ ! -f "$env_file" ]]; then
        return 0
    fi

    sed -n "s/^${key}=//p" "$env_file" | head -1
}

media_dir_requires_mount() {
    local project_dir="${1:-}"
    local media_dir

    media_dir="$(resolve_media_dir "$project_dir")"
    [[ "$media_dir" == /Volumes/* ]]
}

media_mount_reason() {
    local project_dir="${1:-}"
    local media_dir required_dir

    media_dir="$(resolve_media_dir "$project_dir")"

    if media_dir_requires_mount "$project_dir"; then
        if ! mount | grep -F " on $media_dir (" >/dev/null 2>&1; then
            printf 'missing_mount\n'
            return 0
        fi
    elif [[ ! -d "$media_dir" ]]; then
        printf 'local_path_missing\n'
        return 0
    fi

    for required_dir in "$media_dir/Downloads" "$media_dir/Movies" "$media_dir/TV Shows"; do
        if [[ ! -d "$required_dir" ]]; then
            printf 'missing_subdirs\n'
            return 0
        fi
    done

    printf '\n'
}

media_mount_ready() {
    local project_dir="${1:-}"
    [[ -z "$(media_mount_reason "$project_dir")" ]]
}

mount_dependent_services() {
    local project_dir="${1:-}"
    local media_server

    media_server="$(get_env_value_from_project "MEDIA_SERVER" "$project_dir")"
    media_server="${media_server:-plex}"

    printf 'qbittorrent sonarr radarr bazarr'
    if [[ "$media_server" == "jellyfin" ]]; then
        printf ' jellyfin'
    fi
    printf '\n'
}

mount_independent_services() {
    printf 'gluetun prowlarr seerr flaresolverr\n'
}
