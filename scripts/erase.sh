#!/bin/sh

# erase.sh - Clean up SOC Demo environment
# This script deletes all generated certificates and persistent data volumes.

set -e

# --- Environment Setup ---
# Get the absolute path of the script's parent directory (the project root)
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

# --- Helpers ---
log() {
    printf "\033[1;33m[CLEANUP]\033[0m %s\n" "$1"
}

# Ensure we are in the project root by checking for a known file
if [ ! -f "scripts/ssl.sh" ]; then
    echo "Error: Could not determine project root directory."
    exit 1
fi

log "Stopping all Docker containers and removing volumes..."
# Attempt to stop everything if docker-compose is available in each directory
for dir in central regional edge; do
    if [ -d "$dir" ] && [ -f "$dir/docker-compose.yml" ]; then
        log "Cleaning up $dir..."
        (cd "$dir" && docker compose down -v --remove-orphans 2>/dev/null || true)
    fi
done

log "Removing certificate directory..."
rm -rf certs

log "Removing persistent data and state directories..."
# List of data directories from ssl.sh and docker-compose files
DATA_DIRS="
regional/data
central/data
edge/data
"

# State directories hold sentinel files (e.g. .security_initialized).
# These MUST be removed so the next fresh start re-runs security init.
STATE_DIRS="
regional/state
central/state
"

# Since these directories might be owned by root (from Docker), we use sudo if available
if command -v sudo >/dev/null 2>&1; then
    log "Using sudo to remove protected data directories..."
    for dir in $DATA_DIRS $STATE_DIRS; do
        sudo rm -rf "$dir"
    done
else
    log "Removing data and state directories..."
    for dir in $DATA_DIRS $STATE_DIRS; do
        rm -rf "$dir"
    done
fi

log "Cleanup complete. Environment is now in a fresh state."
