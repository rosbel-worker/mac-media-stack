#!/bin/bash
# Update an existing clone to the latest tagged release (vX.Y.Z).
# Safe by default: refuses to run with tracked local changes or local commits ahead of upstream.
# Usage: bash scripts/update-to-latest-release.sh [--yes] [--force] [--skip-setup]

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ASSUME_YES=false
FORCE=false
SKIP_SETUP=false

usage() {
    cat <<EOF
Usage: bash scripts/update-to-latest-release.sh [OPTIONS]

Updates this clone to the latest Git tag that matches v*.

Options:
  --yes         Skip confirmation prompt
  --force       Allow resetting when local branch is ahead of upstream
  --skip-setup  Do not run scripts/setup.sh after updating
  --help        Show this help message
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
        --force)
            FORCE=true
            shift
            ;;
        --skip-setup)
            SKIP_SETUP=true
            shift
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

command -v git >/dev/null 2>&1 || fail "git not found"

PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$PROJECT_DIR" ]] || fail "Not inside a git repository"
cd "$PROJECT_DIR"

origin_url="$(git remote get-url origin 2>/dev/null || true)"
[[ -n "$origin_url" ]] || fail "origin remote not configured"

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    fail "Tracked local changes detected. Commit/stash first, or rerun with --force."
fi

current_branch="$(git symbolic-ref --quiet --short HEAD || true)"
if [[ -n "$current_branch" ]]; then
    upstream="$(git for-each-ref --format='%(upstream:short)' "refs/heads/$current_branch" | head -1)"
    if [[ -n "$upstream" ]]; then
        ahead_count="$(git rev-list --count "$upstream..$current_branch")"
        if [[ "$ahead_count" -gt 0 && "$FORCE" != true ]]; then
            fail "Branch '$current_branch' has $ahead_count local commit(s) ahead of upstream. Rerun with --force to reset."
        fi
    fi
fi

info "Fetching tags from origin..."
git fetch origin --tags --prune >/dev/null

latest_tag="$(git tag -l 'v*' --sort=-version:refname | head -1)"
[[ -n "$latest_tag" ]] || fail "No release tags matching v* were found"

target_sha="$(git rev-list -n1 "$latest_tag")"
current_sha="$(git rev-parse HEAD)"

echo ""
echo "Repo:         $PROJECT_DIR"
echo "Origin:       $origin_url"
echo "Current ref:  ${current_branch:-detached}"
echo "Current SHA:  $current_sha"
echo "Latest tag:   $latest_tag"
echo "Target SHA:   $target_sha"
echo ""

if [[ "$current_sha" == "$target_sha" ]]; then
    log "Already on latest release ($latest_tag)"
else
    if [[ "$ASSUME_YES" != true ]]; then
        read -r -p "Update this clone to $latest_tag? [y/N] " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo "Cancelled."
            exit 0
        fi
    fi

    if [[ -z "$current_branch" ]]; then
        warn "Detached HEAD detected. Checking out 'main' before reset."
        if git show-ref --verify --quiet refs/heads/main; then
            git checkout main >/dev/null
        else
            git checkout -b main >/dev/null
        fi
        current_branch="main"
    fi

    git reset --hard "$target_sha" >/dev/null
    log "Updated $current_branch to $latest_tag"
fi

if [[ "$SKIP_SETUP" != true && -x scripts/setup.sh ]]; then
    media_dir="$(sed -n 's/^MEDIA_DIR=//p' .env 2>/dev/null | head -1)"
    media_dir="${media_dir/#\~/$HOME}"
    info "Running setup sync (scripts/setup.sh)"
    if [[ -n "$media_dir" ]]; then
        bash scripts/setup.sh --media-dir "$media_dir" >/dev/null
    else
        bash scripts/setup.sh >/dev/null
    fi
    log "Setup sync complete"
fi

echo ""
echo "Update complete."
echo "Next steps:"
echo "  1. Review .env if new keys were added"
echo "  2. Restart stack: docker compose up -d"
echo "  3. Verify: bash scripts/health-check.sh"
