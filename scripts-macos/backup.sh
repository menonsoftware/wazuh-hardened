#!/bin/bash

# backup.sh - Wazuh Backup Script for Docker Compose Environment (macOS)
#
# macOS differences from Linux:
#   - tar: BSD tar does not support --ignore-failed-read. We check for path
#     existence before adding to the archive to avoid failures.

set -euo pipefail

# --- Environment Setup ---
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_DIR="${PROJECT_ROOT}/backup"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/wazuh_backup_${TIMESTAMP}.tar.gz"

# Components to backup (relative to PROJECT_ROOT)
BACKUP_PATHS=(
    "central/data"
    "regional/data"
    "edge/data"
    "certs"
    "central/.env"
    "regional/.env"
    "edge/.env"
    ".env"
)

echo "--- Starting Wazuh Backup: ${TIMESTAMP} ---"

# 1. Ensure backup directory exists
mkdir -p "${BACKUP_DIR}"

# 2. Stop Wazuh services to ensure data consistency (Cold Backup)
echo "[*] Stopping Wazuh services for consistent backup..."
(cd "${PROJECT_ROOT}/regional" && docker compose stop)
(cd "${PROJECT_ROOT}/central" && docker compose stop)
(cd "${PROJECT_ROOT}/edge" && docker compose stop)

# 3. Perform the backup
# macOS BSD tar does not support --ignore-failed-read, so we filter to only
# paths that actually exist to prevent tar from erroring on missing paths.
echo "[*] Creating archive: ${BACKUP_FILE}"
EXISTING_PATHS=()
for p in "${BACKUP_PATHS[@]}"; do
    if [ -e "${PROJECT_ROOT}/${p}" ]; then
        EXISTING_PATHS+=("$p")
    else
        echo "[!] Skipping missing path: $p"
    fi
done

if [ ${#EXISTING_PATHS[@]} -eq 0 ]; then
    echo "[-] No backup paths found. Nothing to archive."
else
    tar -czf "${BACKUP_FILE}" -C "${PROJECT_ROOT}" "${EXISTING_PATHS[@]}"
fi

# 4. Restart Wazuh services
echo "[*] Restarting Wazuh services..."
(cd "${PROJECT_ROOT}/regional" && docker compose start)
(cd "${PROJECT_ROOT}/central" && docker compose start)
(cd "${PROJECT_ROOT}/edge" && docker compose start)

# 5. Summary
if [ -f "${BACKUP_FILE}" ]; then
    SIZE=$(du -h "${BACKUP_FILE}" | cut -f1)
    echo "[+] Backup completed successfully!"
    echo "[+] File: ${BACKUP_FILE}"
    echo "[+] Size: ${SIZE}"
else
    echo "[-] Backup failed!"
    exit 1
fi

echo "--- Backup Process Finished ---"
