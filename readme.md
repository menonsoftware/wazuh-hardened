# Wazuh Hardned

Distributed Security Operations Center (SOC) demo built around Wazuh `4.14.4`, deployed as multiple Docker Compose projects:

- `regional/`: Wazuh Indexer cluster + Wazuh Manager
- `central/`: Wazuh Dashboard + Searchhead
- `edge/`: Traefik ingress with Let's Encrypt for browser-facing endpoints
- `scripts/`: Lifecycle automation scripts (Linux)
- `scripts-macos/`: Lifecycle automation scripts (macOS)

## Quick Start

### Linux

```bash
# 0) Host prerequisite (OpenSearch)
sudo sysctl -w vm.max_map_count=262144

# 1) (Optional) persist across reboots
echo "vm.max_map_count=262144" | sudo tee -a /etc/sysctl.conf

# 2) Configure .env files (root, regional, central, edge)

# 3) Generate certs and prepare data directories
./scripts/ssl.sh

# 4) Start full stack (regional -> central -> edge)
./scripts/start_all.sh

# 5) Verify status
cd regional && docker compose ps
cd ../central && docker compose ps
cd ../edge && docker compose ps
```

### macOS

```bash
# 1) Remove macOS quarantine flag (required after download)
xattr -r -d com.apple.quarantine ./scripts-macos/
chmod +x ./scripts-macos/*.sh

# 2) Configure .env files (root, regional, central, edge)

# 3) Generate certs and prepare data directories
./scripts-macos/ssl.sh

# 4) Start full stack (regional -> central -> edge)
./scripts-macos/start_all.sh

# 5) Verify status
cd regional && docker compose ps
cd ../central && docker compose ps
cd ../edge && docker compose ps
```

> **Note:** On macOS, `vm.max_map_count` is managed inside the Docker Desktop Linux VM. The macOS start script validates this automatically and will prompt you if adjustment is needed.

Endpoints:

- Wazuh Dashboard: `https://<DASHBOARD_FQDN>`

## Architecture

```text
                          +-----------------------------+
                          | EDGE (Ingress)              |
                          | - Traefik (:80/:443)        |
                          +--------------+--------------+
                                         |
                               routes HTTPS to
                                         |
                +------------------------+
                |
  +-------------v-------------+
  | CENTRAL                   |
  | - Dashboard :5601         |
  | - Searchhead :9200        |
  +-------------+-------------+
                | queries regional indexers
                v
  +-----------------------------------------------------------------------------+
  | REGIONAL                                                                    |
  | - Indexer-1 :9200/:9300                                                     |
  | - Indexer-2 :9201/:9301                                                     |
  | - Manager Master :1514/:1515/:55000                                         |
  +-----------------------------------------------------------------------------+
```

Notes:

- `start_all.sh` creates a shared external network `edge-net` (if missing).
- On first run, OpenSearch security initialization is automated in both `regional` and `central` and tracked with sentinel files in `regional/state/` and `central/state/`.

## Prerequisites

### Linux

- Ubuntu 22.04+ recommended
- Docker Engine `20.10+` and Docker Compose `v2`
- OpenSSL
- Hardware baseline for full stack: 24 GB+ RAM (32 GB recommended), 16+ CPU threads, fast SSD
- Host kernel setting for OpenSearch:

```bash
sudo sysctl -w vm.max_map_count=262144
echo "vm.max_map_count=262144" | sudo tee -a /etc/sysctl.conf
```

### macOS

- macOS Ventura or later recommended
- Docker Desktop for Mac (manages `vm.max_map_count` inside its Linux VM)
- OpenSSL (ships as LibreSSL; Homebrew `openssl` also works)
- Hardware baseline: Apple Silicon or Intel Mac with 24 GB+ RAM

## Configuration

Configuration is driven by `.env` files:

- Root `.env`: certificate subject values (`COUNTRY`, `STATE`, `LOCALITY`, `ORGANIZATION`), `DOMAIN`, cert validity
- `regional/.env`, `central/.env`, `edge/.env`: ports, resource limits, credentials, and service-specific settings

Important:

- Keep certificate subject values consistent with OpenSearch DN expectations.
- Set `TRAEFIK_ACME_EMAIL` in `edge/.env` for Let's Encrypt.
- Ensure `DASHBOARD_FQDN` resolves to this host for public TLS.

## Deployment

Recommended sequence (substitute `scripts-macos` for `scripts` on macOS):

```bash
# 1) Generate certificates and prepare data/state directories
./scripts/ssl.sh          # Linux
./scripts-macos/ssl.sh    # macOS

# 2) Start all components in orchestrated order
./scripts/start_all.sh          # Linux
./scripts-macos/start_all.sh    # macOS
```

`start_all.sh` performs:

- `vm.max_map_count` pre-flight validation (Linux checks `/proc`; macOS checks the Docker Desktop VM)
- `edge-net` creation if needed
- Component startup order: `regional` -> `central` -> `edge`
- First-run security bootstrap for indexer/searchhead (`securityadmin.sh`)

Optional build step (if you need to rebuild local images):

```bash
./scripts/build_all.sh          # Linux
./scripts-macos/build_all.sh    # macOS
```

## Access

After all services are healthy:

- Wazuh Dashboard: `https://<DASHBOARD_FQDN>`

Credentials are read from component `.env` files; do not hardcode secrets in docs or compose files.

## Operations

All lifecycle scripts have macOS equivalents in `scripts-macos/`. Use the version matching your OS.

| Action | Linux | macOS |
|---|---|---|
| Start all | `./scripts/start_all.sh` | `./scripts-macos/start_all.sh` |
| Stop all | `./scripts/stop_all.sh` | `./scripts-macos/stop_all.sh` |
| Cold backup | `./scripts/backup.sh` | `./scripts-macos/backup.sh` |
| Full reset | `./scripts/erase.sh` | `./scripts-macos/erase.sh` |
| Update rules | `./scripts/update_rules.sh` | `./scripts-macos/update_rules.sh` |

Logs by component:

```bash
cd regional && docker compose logs -f
cd central && docker compose logs -f
cd edge && docker compose logs -f
```

## Persistence Layout

- `regional/data/`: indexer and manager persistent data
- `central/data/`: searchhead data
- `edge/data/letsencrypt/`: Traefik ACME storage
- `regional/state/`, `central/state/`: script state/sentinel files
- `certs/`: generated CA, admin, and node certificates

## Troubleshooting

Indexer unhealthy or exits quickly:

- **Linux:** Verify `vm.max_map_count=262144` on the host
- **macOS:** Verify inside the Docker Desktop VM: `docker run --rm --privileged alpine sysctl vm.max_map_count`
- Check: `cd regional && docker compose logs wazuh.indexer.1`

Security initialization issues on first run:

- Confirm cert subjects match root `.env` values
- Remove sentinel files only if intentionally re-initializing:
  `regional/state/.security_initialized`, `central/state/.security_initialized`

Permission denied on mounted data:

- **Linux:** Re-run `./scripts/ssl.sh` to recreate directories and apply expected ownership
- **macOS:** Docker Desktop handles file permission mapping transparently; re-run `./scripts-macos/ssl.sh` if needed

macOS "operation not permitted" running scripts:

- Downloaded files are quarantined by macOS Gatekeeper. Remove the flag:
  ```bash
  xattr -r -d com.apple.quarantine ./scripts-macos/
  chmod +x ./scripts-macos/*.sh
  ```

Traefik routes not available:

- Confirm `edge-net` exists and services are attached
- Validate DNS for `DASHBOARD_FQDN`

## Security and Hardening Highlights

- Pinned service image versions in compose files (`wazuh 4.14.4`, `traefik 2.11.24`)
- Resource limits and health checks for production-like behavior
- Read-only mounts for key configs/certs where applicable
- No secrets baked into images; runtime environment variables are used instead

## macOS Scripts — Key Differences

The `scripts-macos/` directory mirrors every script in `scripts/` with the following adaptations:

| Script | macOS Adaptation |
|---|---|
| `ssl.sh` | Skips Docker-based `chown` for data directories; Docker Desktop for Mac handles file permission mapping transparently |
| `start_all.sh` | Replaces `/proc/sys/vm/max_map_count` host check with a Docker Desktop VM-level `sysctl` validation |
| `stop_all.sh` | No changes (POSIX-compatible) |
| `build_all.sh` | No changes (POSIX-compatible) |
| `backup.sh` | Uses path-existence checks instead of GNU tar `--ignore-failed-read` (BSD tar incompatibility) |
| `erase.sh` | Assumes user-owned data directories (Docker Desktop runs as current user); `sudo` used only as fallback |
| `update_rules.sh` | Uses BSD `sed -i ''` syntax instead of GNU `sed -i` |
