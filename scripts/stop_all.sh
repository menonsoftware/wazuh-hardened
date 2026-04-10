#!/bin/sh

# SOC Demo Stop Script
# This script stops all Docker containers for the SOC environment.

# Exit on any error
set -e

# --- Environment Setup ---
# Get the absolute path of the script's parent directory (the project root)
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

# Define project directories
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
