# AGENTS.md

This file provides guidance to WARP (warp.dev) when working with code in this repository.

## Project Overview

Mac Media Stack is a self-hosted media server for macOS, orchestrated via Docker Compose. It wires together Seerr, Radarr, Sonarr, Prowlarr, qBittorrent (via Gluetun VPN), Bazarr, FlareSolverr, and either Plex (native macOS app) or Jellyfin (Docker container). All automation scripts are bash.

## Key Commands

```bash
# Validate all shell scripts (syntax check) — mirrors CI
bash -n bootstrap.sh && find scripts -type f -name '*.sh' -exec bash -n {} +

# Validate compose renders with current .env
docker compose config >/dev/null
docker compose --profile jellyfin config >/dev/null
docker compose --profile autoupdate config >/dev/null

# Run the full CI validation locally (syntax + path usage + compose config)
# Requires .env (copy from .env.example if missing)
cp .env.example .env && docker compose --profile autoupdate config >/dev/null && docker compose --profile jellyfin config >/dev/null && rm .env

# Start the stack
docker compose up -d
docker compose --profile jellyfin up -d    # if using Jellyfin
docker compose --profile autoupdate up -d watchtower  # optional auto-updates

# Health check
bash scripts/health-check.sh

# Preflight validation
bash scripts/doctor.sh

# Auto-configure services after first start
bash scripts/configure.sh

# Refresh pinned image digests
bash scripts/refresh-image-lock.sh

# Safe image update with approval gate, rollback, and auto-commit
bash scripts/update-images.sh
```

There is no test suite beyond the CI validation job (`.github/workflows/validate.yml`), which runs `bash -n` syntax checks on all scripts, verifies that automation scripts don't hardcode `$HOME/Media`, and validates compose config with both profiles.

## Architecture

### Two-Path Model

All scripts resolve two root paths from `.env` (or defaults):

- **MEDIA_DIR** — media content (Movies, TV Shows, Downloads, logs). Can live on an external/network drive (`/Volumes/...`).
- **CONFIG_DIR** — app databases and configs (Radarr, Sonarr, qBittorrent, etc.). Must be on local disk to avoid SQLite lock errors.

Path resolution is centralized in `scripts/lib/media-path.sh` (`resolve_media_dir`, `resolve_config_dir`). Scripts must use these helpers or read from `.env`; **never hardcode `$HOME/Media`** in automation scripts (CI enforces this with `rg`).

### Mount-Dependent vs Mount-Independent Services

Services are split into two groups (defined in `scripts/lib/media-path.sh`):

- **Mount-dependent**: `qbittorrent`, `sonarr`, `radarr`, `bazarr` (plus `jellyfin` when enabled) — require MEDIA_DIR to be available.
- **Mount-independent**: `gluetun`, `prowlarr`, `seerr`, `flaresolverr` — can run without the media mount.

When MEDIA_DIR is unavailable (e.g. external drive unmounted), the auto-healer pauses mount-dependent services instead of restarting them in a crash loop. This distinction is critical when modifying health-check, auto-heal, or compose logic.

### Docker Compose Profiles

- `jellyfin` — enables the Jellyfin container (alternative to native Plex).
- `autoupdate` — enables Watchtower for automatic image updates.

Default `docker compose up -d` only starts core services (no profile). Profile services must be started explicitly.

### Image Pinning

All images in `docker-compose.yml` are pinned by `@sha256:` digest (not tags). `IMAGE_LOCK.md` tracks the digest matrix. Use `scripts/refresh-image-lock.sh` to update digests and `scripts/update-images.sh` for the full approval/deploy/rollback flow.

### Shared Libraries (`scripts/lib/`)

- `runtime.sh` — container runtime detection (OrbStack vs Docker Desktop), `wait_for_service` helper.
- `media-path.sh` — path resolution, mount readiness checks, service grouping (mount-dependent vs independent).

These are sourced by most scripts. Changes here affect the entire stack.

### VPN Configuration

Two VPN providers are supported:

- **ProtonVPN** (default) — uses WireGuard (`WIREGUARD_PRIVATE_KEY`, `WIREGUARD_ADDRESSES`).
- **PIA** — uses OpenVPN (`OPENVPN_USER`, `OPENVPN_PASSWORD`). `VPN_SERVICE_PROVIDER` must be set to `private internet access` (not `pia`).

qBittorrent runs inside Gluetun's network namespace (`network_mode: "service:gluetun"`), so its WebUI port (8080) is exposed through the Gluetun container.

### Auto-Heal System

`scripts/auto-heal.sh` runs via a launchd agent (installed by `scripts/install-auto-heal.sh`). It runs every 5 minutes and on login. When MEDIA_DIR is on `/Volumes/...`, the plist includes `WatchPaths` for faster mount-resume. Logs go to `<MEDIA_DIR>/logs/auto-heal.log` (or `~/Library/Logs/media-stack/` as fallback). Sends macOS notifications after 15 minutes of downtime.

## Script Conventions

- All scripts use `set -euo pipefail` (or `set -e`).
- Color constants (`RED`, `GREEN`, `YELLOW`, `CYAN`, `NC`) are defined locally per script.
- `.env` is never sourced directly (values can contain spaces); scripts use `sed -n 's/^KEY=//p'` to extract values.
- Quote-stripping helper (`strip_wrapping_quotes`) is duplicated across scripts that read `.env` values.
- Scripts must work on both Intel and Apple Silicon Macs.
- macOS-specific tooling: `launchd` (not systemd/cron), `lsof` for port checks, `stat -f %T` for filesystem type detection.
- `configure.sh` stores generated credentials in `<MEDIA_DIR>/state/first-run-credentials.txt` and reuses them across reruns.
