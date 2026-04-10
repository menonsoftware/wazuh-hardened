#!/bin/sh

# SOC Demo Start Script
# This script starts all Docker containers for the SOC environment.

# Exit on any error
set -e

# --- Environment Setup ---
# Get the absolute path of the script's parent directory (the project root)
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

# Define project directories
COMPONENTS="regional central edge"

echo "==========================================="
echo "🚀 Starting Up"
echo "==========================================="
# --- Kernel pre-flight: OpenSearch requires vm.max_map_count >= 262144 ---
CURRENT_MAP_COUNT=$(cat /proc/sys/vm/max_map_count 2>/dev/null || echo 0)
if [ "$CURRENT_MAP_COUNT" -lt 262144 ]; then
    echo "=========================================="
    echo "❌ ERROR: vm.max_map_count is $CURRENT_MAP_COUNT (need >= 262144)"
    echo "   Run: sudo sysctl -w vm.max_map_count=262144"
    echo "   To persist across reboots:"
    echo "   echo 'vm.max_map_count=262144' | sudo tee -a /etc/sysctl.conf"
    echo "=========================================="
    exit 1
fi
echo "✅ vm.max_map_count=$CURRENT_MAP_COUNT (OK)."

# Ensure shared edge network exists for Traefik to route across compose projects.
if ! docker network inspect edge-net >/dev/null 2>&1; then
    echo "🕸️  Creating shared Docker network: edge-net"
    docker network create edge-net >/dev/null
fi

# --- Helper: Initialize OpenSearch Security ---
# Hashes the admin password into internal_users.yml, then runs securityadmin.
# Usage: _init_opensearch_security <container_id> <admin_password> <label>
_init_opensearch_security() {
    _CONTAINER="$1"
    _PASS="$2"
    _LABEL="$3"

    echo "🔐 Initializing $_LABEL Security (first run)..."

    # Generate bcrypt hash of the desired password inside the container,
    # then use awk to replace only the admin user's hash in internal_users.yml.
    # The hash is read by awk from a file to avoid shell expansion of $ characters.
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

    # Push the updated security configuration to the OpenSearch security index
    docker exec "$_CONTAINER" sh -c "export JAVA_HOME=/usr/share/wazuh-indexer/jdk/; /usr/share/wazuh-indexer/plugins/opensearch-security/tools/securityadmin.sh -cd /usr/share/wazuh-indexer/config/opensearch-security/ -icl -nhnv -cacert /usr/share/wazuh-indexer/config/certs/root-ca.pem -cert /usr/share/wazuh-indexer/config/certs/admin.pem -key /usr/share/wazuh-indexer/config/certs/admin-key.pem -h localhost"

    sleep 3
    # Verify the new password works
    if docker exec "$_CONTAINER" curl -k -sf -u "admin:$_PASS" "https://localhost:9200/" >/dev/null 2>&1; then
        echo "✅ $_LABEL admin password verified."
    else
        echo "⚠️  Could not verify $_LABEL admin password. Check logs."
    fi
}

# Optional: Check for certificates
if [ ! -d "certs" ] || [ -z "$(ls -A certs)" ]; then
    echo "⚠️  Warning: certs/ directory is missing or empty."
    echo "It is recommended to run ./scripts/ssl.sh before starting to ensure certificates are available for volume mounts."
    echo ""
fi

# --- DN Pre-flight Validation ---
# Validates that generated certificates match the hardcoded DNs in opensearch.yml.
# A mismatch causes Wazuh Indexer security init to fail silently.
if [ -f "certs/admin.pem" ] && command -v openssl >/dev/null 2>&1; then
    CERT_SUBJECT=$(openssl x509 -noout -subject -in certs/admin.pem 2>/dev/null | sed 's/subject=//')
    # Normalize spaces around '=' so both "O=Acme" and "O = Acme" match.
    CERT_SUBJECT_NORM=$(echo "$CERT_SUBJECT" | sed 's/ *= */=/g')
    # Load ORGANIZATION from root .env if present
    _ORG=""
    if [ -f ".env" ]; then
        _ORG=$(grep '^ORGANIZATION=' .env | head -1 | cut -d'=' -f2- | tr -d '"')
    fi
    # Verify cert subject contains the expected Organization
    if [ -n "$_ORG" ] && ! echo "$CERT_SUBJECT_NORM" | grep -qF "O=$_ORG"; then
        echo "=========================================="
        echo "❌ ERROR: DN mismatch detected!"
        echo "   certs/admin.pem subject: $CERT_SUBJECT"
        echo "   .env ORGANIZATION:       $_ORG"
        echo "   The certificate O= field does not match .env ORGANIZATION."
        echo "   opensearch.yml admin_dn/nodes_dn will not match the cert."
        echo "   Run ./scripts/ssl.sh to regenerate certificates."
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

            # Special handling for central: start searchhead first, init
            # security, then start dashboard. The dashboard depends on
            # service_healthy for searchhead, but the healthcheck uses the
            # custom password which only works after security init.
            if [ "$component" = "central" ]; then
                docker compose up -d wazuh.searchhead
            else
                docker compose up -d
            fi
            
            # Security initialization for OpenSearch-based services
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

                # The dashboard now connects directly to the regional indexer
                # cluster (via host-gateway) which holds the wazuh-alerts
                # templates and data. No template sync needed on searchhead.
                echo "ℹ️  Dashboard configured to query regional indexer directly."

                # Now start the dashboard — searchhead healthcheck will pass.
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
