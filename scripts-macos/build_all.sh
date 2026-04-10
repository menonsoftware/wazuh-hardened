#!/bin/sh

# SOC Demo Build Script (macOS)
# Builds all custom Docker containers for the SOC environment.
# No macOS-specific changes needed — this script is POSIX-compatible.

set -e

# --- Environment Setup ---
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

COMPONENTS="regional central edge"

echo "==========================================="
echo "🚀 Starting SOC Demo Build Process"
echo "==========================================="

if [ ! -d "certs" ] || [ -z "$(ls -A certs)" ]; then
    echo "⚠️  Warning: certs/ directory is missing or empty."
    echo "It is recommended to run ./scripts-macos/ssl.sh before building to ensure certificates are available for volume mounts."
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
