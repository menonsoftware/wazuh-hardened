#!/bin/sh

# SOC Demo Start Script (macOS)
# Starts all Docker containers for the SOC environment.
#
# macOS differences from Linux:
#   - vm.max_map_count: Docker Desktop for Mac manages this inside its
#     Linux VM automatically. The /proc check is replaced with a Docker
#     Desktop verification and an informational sysctl hint.

set -e

# --- Environment Setup ---
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

COMPONENTS="regional central edge"

echo "==========================================="
echo "🚀 Starting Up"
echo "==========================================="

# --- Kernel pre-flight: Docker Desktop for Mac ---
# On macOS, /proc/sys/vm/max_map_count does not exist on the host. Docker
# Desktop for Mac runs containers inside a lightweight Linux VM where
# vm.max_map_count is typically set to 262144 by default. We verify Docker
# is reachable and hint at the VM-level sysctl if needed.
if ! docker info >/dev/null 2>&1; then
    echo "=========================================="
    echo "❌ ERROR: Docker is not running."
    echo "   Please start Docker Desktop for Mac."
    echo "=========================================="
    exit 1
fi

# Check vm.max_map_count inside the Docker Desktop VM
VM_MAP_COUNT=$(docker run --rm --privileged alpine sysctl -n vm.max_map_count 2>/dev/null || echo 0)
if [ "$VM_MAP_COUNT" -lt 262144 ] 2>/dev/null; then
    echo "=========================================="
    echo "⚠️  WARNING: vm.max_map_count inside Docker VM is $VM_MAP_COUNT (need >= 262144)"
    echo "   OpenSearch may fail to start."
    echo "   To fix, run:"
    echo "     docker run --rm --privileged alpine sysctl -w vm.max_map_count=262144"
    echo "   Or add to ~/Library/Group Containers/group.com.docker/settings-store.json:"
    echo '     "vm.max_map_count": 262144'
    echo "=========================================="
    exit 1
fi
echo "✅ vm.max_map_count=$VM_MAP_COUNT inside Docker VM (OK)."

# Ensure shared edge network exists for Traefik to route across compose projects.
if ! docker network inspect edge-net >/dev/null 2>&1; then
    echo "🕸️  Creating shared Docker network: edge-net"
    docker network create edge-net >/dev/null
fi

# --- Helper: Initialize OpenSearch Security ---
_init_opensearch_security() {
    _CONTAINER="$1"
    _PASS="$2"
    _LABEL="$3"

    echo "🔐 Initializing $_LABEL Security (first run)..."

    docker exec -e "PASS=$_PASS" "$_CONTAINER" sh -c '
      export JAVA_HOME=/usr/share/wazuh-indexer/jdk
      /usr/share/wazuh-indexer/plugins/opensearch-security/tools/hash.sh -p "$PASS" > /tmp/admin_hash.txt
      FILE=/usr/share/wazuh-indexer/config/opensearch-security/internal_users.yml
      awk '\''
        NR==FNR {hash=$0; next}
        /^admin:/{a=1}
        a && /^  hash:/{$0="  hash: \"" hash "\""; a=0}
        {print}
      '\'' /tmp/admin_hash.txt "$FILE" > /tmp/iu.yml
      cp /tmp/iu.yml "$FILE"
      rm /tmp/admin_hash.txt /tmp/iu.yml
    '

    docker exec "$_CONTAINER" sh -c "export JAVA_HOME=/usr/share/wazuh-indexer/jdk/; /usr/share/wazuh-indexer/plugins/opensearch-security/tools/securityadmin.sh -cd /usr/share/wazuh-indexer/config/opensearch-security/ -icl -nhnv -cacert /usr/share/wazuh-indexer/config/certs/root-ca.pem -cert /usr/share/wazuh-indexer/config/certs/admin.pem -key /usr/share/wazuh-indexer/config/certs/admin-key.pem -h localhost"

    sleep 3
    if docker exec "$_CONTAINER" curl -k -sf -u "admin:$_PASS" "https://localhost:9200/" >/dev/null 2>&1; then
        echo "✅ $_LABEL admin password verified."
    else
        echo "⚠️  Could not verify $_LABEL admin password. Check logs."
    fi
}

# Optional: Check for certificates
if [ ! -d "certs" ] || [ -z "$(ls -A certs)" ]; then
    echo "⚠️  Warning: certs/ directory is missing or empty."
    echo "It is recommended to run ./scripts-macos/ssl.sh before starting to ensure certificates are available for volume mounts."
    echo ""
fi

# --- DN Pre-flight Validation ---
if [ -f "certs/admin.pem" ] && command -v openssl >/dev/null 2>&1; then
    CERT_SUBJECT=$(openssl x509 -noout -subject -in certs/admin.pem 2>/dev/null | sed 's/subject=//')
    CERT_SUBJECT_NORM=$(echo "$CERT_SUBJECT" | sed 's/ *= */=/g')
    _ORG=""
    if [ -f ".env" ]; then
        _ORG=$(grep '^ORGANIZATION=' .env | head -1 | cut -d'=' -f2- | tr -d '"')
    fi
    if [ -n "$_ORG" ] && ! echo "$CERT_SUBJECT_NORM" | grep -qF "O=$_ORG"; then
        echo "=========================================="
        echo "❌ ERROR: DN mismatch detected!"
        echo "   certs/admin.pem subject: $CERT_SUBJECT"
        echo "   .env ORGANIZATION:       $_ORG"
        echo "   The certificate O= field does not match .env ORGANIZATION."
        echo "   opensearch.yml admin_dn/nodes_dn will not match the cert."
        echo "   Run ./scripts-macos/ssl.sh to regenerate certificates."
        echo "=========================================="
        exit 1
    fi
    echo "✅ DN pre-flight check passed (cert O= matches .env ORGANIZATION)."
fi

FAILED_COMPONENTS=""
for component in $COMPONENTS; do
    if [ -d "$component" ]; then
        echo "-------------------------------------------"
        echo "📦 Starting component: $component"
        echo "-------------------------------------------"
        if ! (
            cd "$component"

            if [ "$component" = "central" ]; then
                docker compose up -d wazuh.searchhead
            else
                docker compose up -d
            fi

            if [ "$component" = "regional" ]; then
                INDEXER_CONTAINER=$(docker compose ps -q wazuh.indexer.1)
                echo "⏳ Waiting for Wazuh Indexer to respond on port 9200..."
                until docker exec "$INDEXER_CONTAINER" curl -k -s https://localhost:9200 > /dev/null 2>&1; do
                    printf "."
                    sleep 5
                done
                echo ""
                SENTINEL="./state/.security_initialized"
                if [ ! -f "$SENTINEL" ]; then
                    ADMIN_PASS=$(grep '^INDEXER_PASSWORD=' .env | cut -d'=' -f2-)
                    _init_opensearch_security "$INDEXER_CONTAINER" "$ADMIN_PASS" "Indexer"
                    touch "$SENTINEL"
                    echo "✅ Regional security initialized. Sentinel written to $SENTINEL"
                else
                    echo "ℹ️  Regional security already initialized (sentinel found). Skipping."
                fi

            elif [ "$component" = "central" ]; then
                SEARCHHEAD_CONTAINER=$(docker compose ps -q wazuh.searchhead)
                echo "⏳ Waiting for Searchhead to respond on port 9200..."
                until docker exec "$SEARCHHEAD_CONTAINER" curl -k -s https://localhost:9200 > /dev/null 2>&1; do
                    printf "."
                    sleep 5
                done
                echo ""
                SENTINEL="./state/.security_initialized"
                if [ ! -f "$SENTINEL" ]; then
                    ADMIN_PASS=$(grep '^INDEXER_PASSWORD=' .env | cut -d'=' -f2-)
                    _init_opensearch_security "$SEARCHHEAD_CONTAINER" "$ADMIN_PASS" "Searchhead"
                    touch "$SENTINEL"
                    echo "✅ Central security initialized. Sentinel written to $SENTINEL"
                else
                    echo "ℹ️  Central security already initialized (sentinel found). Skipping."
                fi

                echo "ℹ️  Dashboard configured to query regional indexer directly."

                docker compose up -d wazuh.dashboard
            fi
        ); then
            echo "⚠️  Component $component failed. Continuing with remaining components..."
            FAILED_COMPONENTS="$FAILED_COMPONENTS $component"
        fi
    else
        echo "❌ Error: Directory $component not found. Skipping..."
    fi
done

if [ -n "$FAILED_COMPONENTS" ]; then
    echo "=========================================="
    echo "⚠️  Startup completed with failures:$FAILED_COMPONENTS"
    echo "=========================================="
    exit 1
fi

echo "==========================================="
echo "✅ All components started successfully!"
echo "==========================================="
