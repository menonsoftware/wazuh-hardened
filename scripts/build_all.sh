#!/bin/sh

# SOC Demo Build Script
# This script builds all custom Docker containers for the SOC environment.

# Exit on any error
set -e

# --- Environment Setup ---
# Get the absolute path of the script's parent directory (the project root)
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

# Define project directories
COMPONENTS="regional central edge"

echo "==========================================="
echo "🚀 Starting SOC Demo Build Process"
echo "==========================================="

# Optional: Check for certificates
if [ ! -d "certs" ] || [ -z "$(ls -A certs)" ]; then
    echo "⚠️  Warning: certs/ directory is missing or empty."
    echo "It is recommended to run ./scripts/ssl.sh before building to ensure certificates are available for volume mounts."
    echo ""
fi

for component in $COMPONENTS; do
    if [ -d "$component" ]; then
        echo "-------------------------------------------"
        echo "📦 Building component: $component"
        echo "-------------------------------------------"
        (
            cd "$component"
            docker compose build
        )
    else
        echo "❌ Error: Directory $component not found. Skipping..."
    fi
done

echo "==========================================="
echo "✅ All components built successfully!"
echo "==========================================="
