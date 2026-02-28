# Image Lock Matrix

This stack is pinned to exact image digests in `docker-compose.yml` for reproducible installs.

Tested lock snapshot:
- Date: `2026-02-28`
- Docker Engine: `28.5.2`
- Platform: `aarch64 (OrbStack)`

| Service | Locked Image |
|---|---|
| bazarr | `lscr.io/linuxserver/bazarr@sha256:b0bc617664dbca25845ac3b1bb6411b145b6a44a6d173071c9d2f426524fdd9f` |
| flaresolverr | `ghcr.io/flaresolverr/flaresolverr@sha256:7962759d99d7e125e108e0f5e7f3cdbcd36161776d058d1d9b7153b92ef1af9e` |
| prowlarr | `lscr.io/linuxserver/prowlarr@sha256:e74a1e093dcc223d671d4b7061e2b4946f1989a4d3059654ff4e623b731c9134` |
| gluetun | `qmcgaw/gluetun@sha256:d26d95d9158cb1cd793821bf9f0eb62c447f370925b274484a70044015e91284` |
| qbittorrent | `lscr.io/linuxserver/qbittorrent@sha256:065792d2b11f0facff340210fc1cf13623b029a94ecdf08b02d06d922205f618` |
| sonarr | `lscr.io/linuxserver/sonarr@sha256:37be832b78548e3f55f69c45b50e3b14d18df1b6def2a4994258217e67efb1a1` |
| watchtower (optional) | `containrrr/watchtower@sha256:6dd50763bbd632a83cb154d5451700530d1e44200b268a4e9488fefdfcf2b038` |
| jellyfin (optional) | `lscr.io/linuxserver/jellyfin@sha256:ba3773e77f0bf571e44cb2aad028f240cfac6b1bb261634c5762992995b50b89` |
| radarr | `lscr.io/linuxserver/radarr@sha256:6d3e68474ea146f995af98d3fb2cb1a14e2e4457ddaf035aa5426889e2f9249c` |
| seerr | `ghcr.io/seerr-team/seerr@sha256:b35ba0461c4a1033d117ac1e5968fd4cbe777899e4cbfbdeaf3d10a42a0eb7e9` |

## Updating The Lock

Run:
```bash
bash scripts/refresh-image-lock.sh
```

Then smoke test the stack and commit the updated lock files.
