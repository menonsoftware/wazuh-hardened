#!/bin/sh

# SOC Demo Stop Script (macOS)
# Stops all Docker containers for the SOC environment.
# No macOS-specific changes needed — this script is POSIX-compatible.

set -e

# --- Environment Setup ---
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

COMPONENTS="edge central regional"

echo "==========================================="
echo "🚀 Stopping All Components"
echo "==========================================="

for component in $COMPONENTS; do
    if [ -d "$component" ]; then
        echo "-------------------------------------------"
        echo "📦 Stopping component: $component"
        echo "-------------------------------------------"
        (
            cd "$component"
            docker compose down
        )
    else
        echo "❌ Error: Directory $component not found. Skipping..."
    fi
done

echo "==========================================="
echo "✅ All components stopped successfully!"
echo "==========================================="
