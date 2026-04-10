#!/bin/sh

# ssl.sh - Automated OpenSSL Certificate Generation for Wazuh (macOS)
# macOS-compatible version. Differences from Linux:
#   - Data directory ownership: Docker Desktop for Mac handles file permission
#     mapping transparently, so the Docker chown step is informational only.

set -e

# --- Environment Setup ---
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

# --- Configuration & Defaults ---
ENV_FILE=".env"
OUTPUT_DIR="certs"
NODE_EXT_FILE="node.ext"

# Load environment variables if .env file exists
if [ -f "$ENV_FILE" ]; then
    . "./$ENV_FILE"
fi

# Use values from .env or set defaults
DOMAIN="${DOMAIN:-soc-demo.menonsoftware.lan}"
DAYS="${DAYS:-3650}"
COUNTRY="${COUNTRY:-IN}"
STATE="${STATE:-Maharashtra}"
LOCALITY="${LOCALITY:-Mumbai}"
ORGANIZATION="${ORGANIZATION:-Acme Corporation}"
CN_ROOT="${CN_ROOT:-RootCA}"
CN_ADMIN="${CN_ADMIN:-admin}"

# --- Helpers ---

log() {
    printf "\033[1;32m[INFO]\033[0m %s\n" "$1"
}

error() {
    printf "\033[1;31m[ERROR]\033[0m %s\n" "$1" >&2
    exit 1
}

# Ensure openssl is installed (macOS ships with LibreSSL; Homebrew openssl also works)
command -v openssl >/dev/null 2>&1 || error "openssl is not installed. Install via: brew install openssl"

# Prepare output directory
mkdir -p "$OUTPUT_DIR"

# --- Data Directory Preparation ---
log "Preparing data directories..."

DATA_DIRS="
regional/data/indexer1
regional/data/indexer2
regional/data/master
central/data/searchhead
"

STATE_DIRS="
regional/state
central/state
"

for DIR in $DATA_DIRS; do
    mkdir -p "$DIR"
done

for DIR in $STATE_DIRS; do
    mkdir -p "$DIR"
done

# On Docker Desktop for Mac, file ownership is handled transparently by the
# gRPC-FUSE / VirtioFS file sharing layer. The chown inside an Alpine
# container is harmless but not strictly necessary.
if command -v docker >/dev/null 2>&1; then
    log "Setting ownership (1000:1000) inside Docker context for data volumes..."
    docker run --rm -v "$(pwd):/soc" alpine sh -c "chown -R 1000:1000 /soc/regional/data /soc/central/data"
else
    log "Docker not found. Please install Docker Desktop for Mac."
fi

# --- Certificate Generation ---
cd "$OUTPUT_DIR"

log "Generating Internal Root CA..."
openssl genrsa -out root-ca-key.pem 4096
openssl req -x509 -new -nodes -key root-ca-key.pem -sha256 -days "$DAYS" -out root-ca.pem \
    -subj "/C=$COUNTRY/ST=$STATE/L=$LOCALITY/O=$ORGANIZATION/CN=$CN_ROOT"

log "Generating Admin Certificate..."
openssl genrsa -out admin-key.pem 2048
openssl pkcs8 -in admin-key.pem -topk8 -nocrypt -out admin-key.pem.tmp && mv admin-key.pem.tmp admin-key.pem

openssl req -new -key admin-key.pem -out admin.csr \
    -subj "/C=$COUNTRY/ST=$STATE/L=$LOCALITY/O=$ORGANIZATION/CN=$CN_ADMIN"
openssl x509 -req -in admin.csr -CA root-ca.pem -CAkey root-ca-key.pem -CAcreateserial -out admin.pem -days "$DAYS" -sha256

NODES="master worker1 worker2 indexer1 indexer2 dashboard searchhead helpdesk"

for NODE in $NODES; do
    log "Processing node: $NODE..."

    NODE_EXT="$NODE.ext"

    case $NODE in
        indexer*)
            ALT_NAME="wazuh.indexer.${NODE#indexer}"
            ;;
        master)
            ALT_NAME="wazuh.manager.master"
            ;;
        *)
            ALT_NAME="wazuh.$NODE"
            ;;
    esac

    cat > "$NODE_EXT" << EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = @alt_names
[alt_names]
DNS.1 = $NODE.$DOMAIN
DNS.2 = $NODE
DNS.3 = $ALT_NAME
DNS.4 = localhost
IP.1 = 127.0.0.1
EOF

    openssl genrsa -out "$NODE-key.pem" 2048
    openssl pkcs8 -in "$NODE-key.pem" -topk8 -nocrypt -out "$NODE-key.pem.tmp" && mv "$NODE-key.pem.tmp" "$NODE-key.pem"

    openssl req -new -key "$NODE-key.pem" -out "$NODE.csr" \
        -subj "/C=$COUNTRY/ST=$STATE/L=$LOCALITY/O=$ORGANIZATION/CN=$NODE.$DOMAIN"
    openssl x509 -req -in "$NODE.csr" -CA root-ca.pem -CAkey root-ca-key.pem -CAcreateserial \
        -out "$NODE.pem" -days "$DAYS" -sha256 -extfile "$NODE_EXT"

    rm -f "$NODE_EXT"
done

rm -f *.csr "$NODE_EXT_FILE" root-ca.srl

log "Setting permissions on generated certificates..."
chmod 644 *.pem

log "Certificates generated successfully in the '$OUTPUT_DIR' directory."
log "Mount these into your Docker volumes as needed."
