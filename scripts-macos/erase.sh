#!/bin/sh

# erase.sh - Clean up SOC Demo environment (macOS)
#
# macOS differences from Linux:
#   - Docker Desktop for Mac runs as the current user, so data directories
#     are typically user-owned (no sudo needed). sudo is still attempted as
#     a fallback for any root-owned files.

set -e

# --- Environment Setup ---
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

# --- Helpers ---
log() {
    printf "\033[1;33m[CLEANUP]\033[0m %s\n" "$1"
}

if [ ! -f "scripts-macos/ssl.sh" ] && [ ! -f "scripts/ssl.sh" ]; then
    echo "Error: Could not determine project root directory."
    exit 1
fi

log "Stopping all Docker containers and removing volumes..."
for dir in central regional edge; do
    if [ -d "$dir" ] && [ -f "$dir/docker-compose.yml" ]; then
        log "Cleaning up $dir..."
        (cd "$dir" && docker compose down -v --remove-orphans 2>/dev/null || true)
    fi
done

log "Removing certificate directory..."
rm -rf certs

log "Removing persistent data and state directories..."

DATA_DIRS="
regional/data
central/data
edge/data
"

STATE_DIRS="
regional/state
central/state
"

# On macOS, Docker Desktop typically creates files as the current user,
# so sudo is usually not required. We try without sudo first, then fall
# back to sudo for any stubborn directories.
for dir in $DATA_DIRS $STATE_DIRS; do
    if [ -d "$dir" ]; then
        rm -rf "$dir" 2>/dev/null || {
            if command -v sudo >/dev/null 2>&1; then
                log "Using sudo to remove $dir..."
                sudo rm -rf "$dir"
            else
                log "Warning: Could not remove $dir — permission denied."
            fi
        }
    fi
done

log "Cleanup complete. Environment is now in a fresh state."
