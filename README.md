<div align="center">
  <br>
  <a href="#one-command-install">
    <img src="https://img.shields.io/badge/MAC_MEDIA_STACK-00C853?style=for-the-badge&logo=apple&logoColor=white" alt="Mac Media Stack" height="40" />
  </a>
  <br><br>
  <strong>Self-hosted media server for macOS</strong>
  <br>
  <sub>Automatically find, download, and organize movies and TV shows.<br>Browse a Netflix-like interface, click what you want, and it handles the rest.</sub>
  <br><br>
  <img src="https://img.shields.io/badge/Docker-2496ED?style=flat-square&logo=docker&logoColor=white" />
  <img src="https://img.shields.io/badge/Plex-EBAF00?style=flat-square&logo=plex&logoColor=white" />
  <img src="https://img.shields.io/badge/Sonarr-00CCFF?style=flat-square&logo=sonarr&logoColor=white" />
  <img src="https://img.shields.io/badge/Radarr-FFC230?style=flat-square&logo=radarr&logoColor=black" />
  <img src="https://img.shields.io/badge/qBittorrent-2F67BA?style=flat-square&logo=qbittorrent&logoColor=white" />
  <img src="https://img.shields.io/badge/macOS-000000?style=flat-square&logo=apple&logoColor=white" />
  <br><br>
</div>

## What's Included

| Service | What It Does |
|---------|-------------|
| **Seerr** | Netflix-style UI for browsing and requesting movies/shows |
| **Plex** | Plays your media on any device (TV, phone, laptop) |
| **Radarr** | Automatically finds and downloads movies |
| **Sonarr** | Automatically finds and downloads TV shows |
| **Prowlarr** | Manages search indexers for Radarr/Sonarr |
| **qBittorrent** | Downloads torrents through a VPN tunnel |
| **Gluetun** | VPN container (ProtonVPN WireGuard) so downloads are private |
| **Bazarr** | Auto-fetches subtitles |
| **FlareSolverr** | Bypasses Cloudflare protection on certain indexers |
| **Watchtower** | Keeps everything updated automatically |

## Requirements

- macOS (any recent version)
- Docker Desktop
- A Plex account (free)
- ProtonVPN WireGuard credentials

## One-Command Install

Requires Docker Desktop and Plex already installed. Handles everything else.

```bash
curl -fsSL https://raw.githubusercontent.com/liamvibecodes/mac-media-stack/main/bootstrap.sh | bash
```

## Manual Quick Start

If you prefer to run each step yourself:

```bash
git clone https://github.com/liamvibecodes/mac-media-stack.git
cd mac-media-stack
bash scripts/setup.sh        # creates folders, generates .env
# edit .env and add your VPN keys
docker compose up -d          # start everything
bash scripts/configure.sh     # auto-configure all services
```

## Full Setup Guide

See [SETUP.md](SETUP.md) for the complete step-by-step walkthrough.

## Scripts

| Script | Purpose |
|--------|---------|
| `scripts/setup.sh` | Creates folder structure and .env file |
| `scripts/configure.sh` | Auto-configures all service connections |
| `scripts/health-check.sh` | Checks if everything is running correctly |
| `scripts/auto-heal.sh` | Hourly self-healer (restarts VPN/containers if down) |
| `scripts/install-auto-heal.sh` | Installs auto-heal as a background job via launchd |

## Day-to-Day Usage

| What | Where |
|------|-------|
| Browse and request movies/shows | http://localhost:5055 |
| Watch your media | http://localhost:32400/web |

Everything else is automatic. Requests get searched, downloaded, imported, and subtitled without any manual steps.

## Architecture

```
You (Seerr) -> Radarr/Sonarr -> Prowlarr (search) -> qBittorrent (download via VPN) -> Plex (watch)
                                                        Bazarr (subtitles) ^
```

All services run as Docker containers. Plex runs natively on macOS. Download traffic routes through ProtonVPN. Everything else uses your normal internet connection.

## Looking for More?

Check out [mac-media-stack-advanced](https://github.com/liamvibecodes/mac-media-stack-advanced) for the full power-user setup with transcoding (Tdarr), TRaSH quality profiles (Recyclarr), Plex metadata automation (Kometa), download watchdog, VPN failover, automated backups, and more.
