#!/bin/bash
# Installs the auto-heal launchd job (runs every 5 minutes).
# Usage: bash scripts/install-auto-heal.sh [--help]

set -euo pipefail

GREEN='\033[0;32m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/lib/media-path.sh
source "$SCRIPT_DIR/lib/media-path.sh"

MEDIA_DIR="$(resolve_media_dir "$PROJECT_DIR")"
LAUNCH_DIR="$HOME/Library/LaunchAgents"
LOG_DIR="$HOME/Library/Logs/media-stack/launchd"
PLIST_NAME="com.media-stack.auto-heal"
PLIST_PATH="$LAUNCH_DIR/$PLIST_NAME.plist"
WATCH_PATHS_XML=""

usage() {
    cat <<EOF
Usage: bash scripts/install-auto-heal.sh

Installs the auto-heal launchd job (every 5 minutes + on login).

Options:
  --help    Show this help message
EOF
}

case "${1:-}" in
    "" ) ;;
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

mkdir -p "$LAUNCH_DIR" "$LOG_DIR"

if media_dir_requires_mount "$PROJECT_DIR"; then
    WATCH_PATHS_XML=$(cat <<EOF
    <key>WatchPaths</key>
    <array>
        <string>/Volumes</string>
        <string>$MEDIA_DIR</string>
    </array>
EOF
)
fi

cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$PLIST_NAME</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$SCRIPT_DIR/auto-heal.sh</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>WorkingDirectory</key>
    <string>$PROJECT_DIR</string>
    <key>StartInterval</key>
    <integer>300</integer>
    <key>RunAtLoad</key>
    <true/>
${WATCH_PATHS_XML}
    <key>StandardOutPath</key>
    <string>$LOG_DIR/auto-heal.out.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/auto-heal.err.log</string>
</dict>
</plist>
EOF

launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"

echo -e "${GREEN}Auto-heal installed.${NC} Runs every 5 minutes + on login."
echo "Auto-heal logs: $MEDIA_DIR/logs/auto-heal.log (when media mount is ready)"
echo "Fallback logs + launchd logs: $HOME/Library/Logs/media-stack/"
echo ""
echo "To uninstall: launchctl unload $PLIST_PATH && rm $PLIST_PATH"
