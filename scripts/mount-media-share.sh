#!/bin/bash
# Mounts MEDIA_SHARE_URL and waits for MEDIA_DIR to become ready.
# Usage: bash scripts/mount-media-share.sh [--wait SECONDS] [--help]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/lib/media-path.sh
source "$SCRIPT_DIR/lib/media-path.sh"

WAIT_SECONDS=30

usage() {
    cat <<EOF
Usage: bash scripts/mount-media-share.sh [OPTIONS]

Attempt to mount MEDIA_SHARE_URL and wait for MEDIA_DIR to become ready.

Options:
  --wait SECONDS  Seconds to wait for the mount (default: 30)
  --help          Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --wait)
            if [[ $# -lt 2 || "$2" == --* ]]; then
                echo "Missing value for --wait"
                usage
                exit 1
            fi
            WAIT_SECONDS="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

MEDIA_DIR="$(resolve_media_dir "$PROJECT_DIR")"
MEDIA_SHARE_URL="$(resolve_media_share_url "$PROJECT_DIR")"

if ! media_dir_requires_mount "$PROJECT_DIR"; then
    echo "MEDIA_DIR is not under /Volumes; no network share mount is required."
    exit 0
fi

if media_mount_ready "$PROJECT_DIR"; then
    echo "Media mount already ready: $MEDIA_DIR"
    exit 0
fi

if [[ -z "$MEDIA_SHARE_URL" ]]; then
    echo "MEDIA_SHARE_URL is not set in .env; cannot auto-mount $MEDIA_DIR."
    exit 1
fi

echo "Attempting to mount configured media share for $MEDIA_DIR..."
if mount_media_share "$PROJECT_DIR" "$WAIT_SECONDS"; then
    echo "Media mount ready: $MEDIA_DIR"
    exit 0
fi

echo "Media mount is still unavailable: $MEDIA_DIR"
exit 1
