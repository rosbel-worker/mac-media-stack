# Image Lock Matrix

This stack is pinned to exact image digests in `docker-compose.yml` for reproducible installs.

Tested lock snapshot:
- Date: `2026-02-22`
- Docker Engine: `29.2.1`
- Platform: `aarch64 (Docker Desktop)`

| Service | Locked Image |
|---|---|
| bazarr | `lscr.io/linuxserver/bazarr@sha256:1cf40186b1bc35bec87f4e4892d5d8c06086da331010be03e3459a86869c5e74` |
| flaresolverr | `ghcr.io/flaresolverr/flaresolverr@sha256:7962759d99d7e125e108e0f5e7f3cdbcd36161776d058d1d9b7153b92ef1af9e` |
| gluetun | `qmcgaw/gluetun@sha256:495cdc65ace4c110cf4de3d1f5f90e8a1dd2eb0f8b67151d1ad6101b2a02a476` |
| qbittorrent | `lscr.io/linuxserver/qbittorrent@sha256:85eb27d2d09cd4cb748036a4c7f261321da516b6f88229176cf05a92ccd26815` |
| radarr | `lscr.io/linuxserver/radarr@sha256:6d3e68474ea146f995af98d3fb2cb1a14e2e4457ddaf035aa5426889e2f9249c` |
| sonarr | `lscr.io/linuxserver/sonarr@sha256:37be832b78548e3f55f69c45b50e3b14d18df1b6def2a4994258217e67efb1a1` |
| prowlarr | `lscr.io/linuxserver/prowlarr@sha256:e74a1e093dcc223d671d4b7061e2b4946f1989a4d3059654ff4e623b731c9134` |
| seerr | `ghcr.io/seerr-team/seerr@sha256:1b5fc1ea825631d9d165364472663b817a4c58ef6aa1013f58d82c1570d7c866` |
| jellyfin (optional) | `lscr.io/linuxserver/jellyfin@sha256:4ee07757abcaa0b74fbc74179392311dc2874c03b0bef04bc2d79e9e1a875793` |
| watchtower (optional) | `containrrr/watchtower@sha256:6dd50763bbd632a83cb154d5451700530d1e44200b268a4e9488fefdfcf2b038` |

## Updating The Lock

Run:
```bash
bash scripts/refresh-image-lock.sh
```

Then smoke test the stack and commit the updated lock files.
