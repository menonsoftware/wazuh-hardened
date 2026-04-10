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

### Software

| Tool | Version | Notes |
|------|---------|-------|
| Docker Engine | `20.10+` | Must support Compose file format 3.8+ |
| Docker Compose | `v2` | CLI plugin (`docker compose`, not `docker-compose`) |
| OpenSSL | any | Used by `ssl.sh` for TLS cert generation |
| Python 3 | `3.8+` | Only needed if using `init_secrets.py` for interactive `.env` setup |
| bash | any | Only needed for `backup.sh`; all other scripts use POSIX `sh` |
| tar | any | Only needed for `backup.sh` |

### Hardware (minimum for full stack at ~1k agents)

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| RAM | 24 GB | 32 GB |
| CPU | 8 threads | 16+ threads |
| Disk | 100 GB SSD | 250 GB+ SSD (fast I/O required by OpenSearch) |

Disk breakdown:
- `regional/data/` — 50–100 GB+ per indexer (depends on log volume)
- `central/data/` — 20–50 GB (searchhead)
- `edge/data/letsencrypt/` — < 1 MB (ACME cache)
- `certs/` — < 1 MB (generated certificates)

### Network Ports

The following host ports must be available (defaults from `.env` files):

| Port | Service | Protocol |
|------|---------|----------|
| `80` | Traefik HTTP → HTTPS redirect | TCP |
| `443` | Traefik HTTPS (Dashboard ingress) | TCP |
| `1514` | Wazuh Manager (agent enrollment) | TCP |
| `1515` | Wazuh Manager (enrollment protocol) | TCP |
| `9200` | Indexer-1 REST API | TCP/HTTPS |
| `9201` | Indexer-2 REST API | TCP/HTTPS |
| `9300` | Indexer-1 cluster transport | TCP |
| `9301` | Indexer-2 cluster transport | TCP |
| `55000` | Wazuh Manager REST API | TCP/HTTPS |

### Host Kernel Settings

OpenSearch requires a higher virtual memory map limit:

**Linux:**

```bash
sudo sysctl -w vm.max_map_count=262144
# persist across reboots
echo "vm.max_map_count=262144" | sudo tee -a /etc/sysctl.conf
```

**macOS:** Managed automatically inside the Docker Desktop Linux VM. The macOS start script validates this and will prompt you if adjustment is needed.

### DNS

`DASHBOARD_FQDN` (set in `edge/.env`) must resolve to the host running the stack. Traefik uses this hostname for Let's Encrypt certificate issuance — if DNS does not point to the host, ACME HTTP-01 challenges will fail and the dashboard will not be reachable over HTTPS.

For local/lab deployments, add the FQDN to `/etc/hosts` on the host and any client machines.

### OS-Specific Notes

**Linux:**
- Ubuntu 22.04+ recommended (kernel 5.10+)

**macOS:**
- macOS Ventura or later recommended (Apple Silicon or Intel)
- Docker Desktop for Mac required
- OpenSSL ships as LibreSSL; Homebrew `openssl` also works

### Environment Files

Before first run, configure these `.env` files:

| File | Key Settings |
|------|-------------|
| Root `.env` | Certificate subject (`COUNTRY`, `STATE`, `LOCALITY`, `ORGANIZATION`), `DOMAIN`, cert validity (`DAYS`) |
| `regional/.env` | Indexer/Manager resource limits, ports, credentials (`OPENSEARCH_INITIAL_ADMIN_PASSWORD`) |
| `central/.env` | Searchhead/Dashboard resource limits, `DASHBOARD_FQDN`, remote indexer endpoints |
| `edge/.env` | `TRAEFIK_ACME_EMAIL` for Let's Encrypt, Traefik resource limits |

> **Important:** Certificate subject values in the root `.env` must match the `admin_dn` / `nodes_dn` entries in `opensearch.yml` or security initialization will fail silently.

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
