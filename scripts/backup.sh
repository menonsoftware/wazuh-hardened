#!/bin/bash

# backup.sh - Wazuh Backup Script for Docker Compose Environment
# Follows best practices for cold backups to ensure data consistency.

# Set strict mode
set -euo pipefail

# --- Environment Setup ---
# Get the absolute path of the script's parent directory (the project root)
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
echo "[*] Creating archive: ${BACKUP_FILE}"
# We use -C to change directory to project root and then add the paths
# We use --ignore-failed-read to not fail if some data dirs don't exist yet
tar -czf "${BACKUP_FILE}" -C "${PROJECT_ROOT}" "${BACKUP_PATHS[@]}" --ignore-failed-read

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
