#!/bin/bash
# Shared MEDIA_DIR resolver.
# Priority: explicit MEDIA_DIR env var -> .env MEDIA_DIR -> ~/Media

resolve_media_dir() {
    local project_dir="${1:-}"
    local env_file media_dir

    if [[ -z "$project_dir" ]]; then
        project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    fi

    env_file="$project_dir/.env"
    media_dir="${MEDIA_DIR:-}"

    if [[ -z "$media_dir" && -f "$env_file" ]]; then
        media_dir="$(sed -n 's/^MEDIA_DIR=//p' "$env_file" | head -1)"
    fi

    media_dir="${media_dir%\"}"
    media_dir="${media_dir#\"}"
    media_dir="${media_dir%\'}"
    media_dir="${media_dir#\'}"
    media_dir="${media_dir:-$HOME/Media}"
    media_dir="${media_dir/#\~/$HOME}"

    printf '%s\n' "$media_dir"
}
