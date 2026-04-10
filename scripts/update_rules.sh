#!/bin/sh
# update_rules.sh — Sync SOCFortress Wazuh community rules into the manager.
#
# Safe to run during provisioning (before first start) and on subsequent
# updates to pull the latest rules. Idempotent.
#
# Usage:
#   ./scripts/update_rules.sh             # sync + reload running manager
#   ./scripts/update_rules.sh --no-reload # sync only; apply on next start
#======================================================================================
# First-time provisioning (manager not yet running — stages everything)
# ./scripts/update_rules.sh --no-reload

# # Normal provisioning (manager is running — patches live)
# ./scripts/update_rules.sh

# # Refresh rules after an upstream update
# ./scripts/update_rules.sh

set -e

RULES_REPO="https://github.com/socfortress/Wazuh-Rules"
RULES_SUBDIR="socfortress"   # namespaced subdir under etc/rules/, etc/decoders/, etc/lists/
MANAGER_SERVICE="wazuh.manager.master"

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RULES_DIR="$PROJECT_ROOT/regional/rules"
DECODERS_DIR="$PROJECT_ROOT/regional/decoders"
LISTS_DIR="$PROJECT_ROOT/regional/lists"
OSSEC_CONF_HOST="$PROJECT_ROOT/regional/ossec.conf"
COMPOSE_FILE="$PROJECT_ROOT/regional/docker-compose.yml"

# --- Helpers ---
log()   { printf "\033[1;32m[INFO]\033[0m %s\n" "$1"; }
warn()  { printf "\033[1;33m[WARN]\033[0m %s\n" "$1"; }
error() { printf "\033[1;31m[ERROR]\033[0m %s\n" "$1" >&2; exit 1; }

TMP_DIR=$(mktemp -d)
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

NO_RELOAD=""
for arg in "$@"; do
    case "$arg" in --no-reload) NO_RELOAD=1 ;; esac
done

echo "==========================================="
echo "   SOCFortress Wazuh Rules — Update"
echo "==========================================="

# --- 1. Prerequisites ---
command -v git    >/dev/null 2>&1 || error "git is required. Install with: apt-get install -y git"
command -v docker >/dev/null 2>&1 || error "docker is required."
command -v awk    >/dev/null 2>&1 || error "awk is required."

# --- 2. Clone latest SOCFortress rules ---
log "Cloning $RULES_REPO ..."
git clone --depth=1 --quiet "$RULES_REPO" "$TMP_DIR/wazuh-rules" \
    || error "Failed to clone $RULES_REPO — check internet connectivity."

# Count XML files found in the repo
XML_COUNT=$(find "$TMP_DIR/wazuh-rules" -name '*.xml' -not -path '*/.git/*' | wc -l | tr -d ' ')
[ "$XML_COUNT" -gt 0 ] || error "No XML rule files found in $RULES_REPO — unexpected repo layout."
log "Found $XML_COUNT rule file(s) in the repository."

# --- 3. Sort XML files: decoders → regional/decoders/, rules → regional/rules/ ---
# Decoder files contain <decoder name="...">; everything else is a rule file.
# List paths inside rule files are rewritten from the generic 'etc/lists/X'
# to the namespaced 'etc/lists/$RULES_SUBDIR/X' so we can mount a dedicated
# directory without touching built-in Wazuh CDB lists.
mkdir -p "$RULES_DIR" "$DECODERS_DIR"
find "$TMP_DIR/wazuh-rules" -name '*.xml' -not -path '*/.git/*' | while IFS= read -r f; do
    if grep -ql '<decoder name' "$f"; then
        cp "$f" "$DECODERS_DIR/"
    else
        # Rewrite list references to the namespaced subdir.
        # Guard against double-rewriting on re-runs by deduplicating the prefix.
        sed "s|etc/lists/|etc/lists/${RULES_SUBDIR}/|g" "$f" \
            | sed "s|etc/lists/${RULES_SUBDIR}/${RULES_SUBDIR}/|etc/lists/${RULES_SUBDIR}/|g" \
            > "$RULES_DIR/$(basename "$f")"
    fi
done
SYNCED_RULES=$(find "$RULES_DIR" -name '*.xml' | wc -l | tr -d ' ')
SYNCED_DECODERS=$(find "$DECODERS_DIR" -name '*.xml' | wc -l | tr -d ' ')
log "Synced $SYNCED_RULES rule file(s) and $SYNCED_DECODERS decoder file(s)."

# --- 3b. Sync CDB list files referenced by the rules ---
# Prefer real list assets from the upstream repo when present. The dashboard
# CDB Lists UI rejects zero-byte files as "Bad format", so if no upstream list
# exists we seed a minimal valid placeholder entry instead.
mkdir -p "$LISTS_DIR"
grep -rh "etc/lists/${RULES_SUBDIR}/" "$RULES_DIR" 2>/dev/null \
    | grep -o "etc/lists/${RULES_SUBDIR}/[^<\"]*" | sort -u \
    | while IFS= read -r lpath; do
        lname=$(basename "$lpath")
        LIST_SOURCE=$(find "$TMP_DIR/wazuh-rules" -type f -name "$lname" | head -n 1)
        if [ -n "$LIST_SOURCE" ]; then
            rm -f "$LISTS_DIR/$lname"
            cp "$LIST_SOURCE" "$LISTS_DIR/$lname"
            chmod 644 "$LISTS_DIR/$lname"
            log "Synced upstream CDB list: regional/lists/$lname"
        elif [ ! -s "$LISTS_DIR/$lname" ]; then
            rm -f "$LISTS_DIR/$lname"
            case "$lname" in
                common-ports)
                    printf '65535:placeholder\n' > "$LISTS_DIR/$lname"
                    ;;
                bash_profile)
                    printf '/tmp/.placeholder:placeholder\n' > "$LISTS_DIR/$lname"
                    ;;
                *)
                    printf '__placeholder__:placeholder\n' > "$LISTS_DIR/$lname"
                    ;;
            esac
            chmod 644 "$LISTS_DIR/$lname"
            log "Seeded stub CDB list: regional/lists/$lname (replace placeholder data before production use)"
        fi
    done
SYNCED=$(find "$RULES_DIR" -name '*.xml' | wc -l | tr -d ' ')

# --- 4. Ensure all three volume mounts exist in compose (idempotent) ---
# Track whether any new mount was added — any addition requires a container recreate.
NEW_MOUNTS=""
if ! grep -qF "./rules:/var/ossec/etc/rules/$RULES_SUBDIR" "$COMPOSE_FILE"; then
    sed -i "s|      - ./data/master:/var/ossec/data|      - ./data/master:/var/ossec/data\n      - ./rules:/var/ossec/etc/rules/$RULES_SUBDIR:ro\n      - ./decoders:/var/ossec/etc/decoders/$RULES_SUBDIR:ro\n      - ./lists:/var/ossec/etc/lists/$RULES_SUBDIR|" \
        "$COMPOSE_FILE"
    log "Added rules/decoders/lists volume mounts to docker-compose.yml"
    NEW_MOUNTS=1
else
    # Rules mount already there — check decoders and lists individually
    if ! grep -qF "./decoders:/var/ossec/etc/decoders/$RULES_SUBDIR" "$COMPOSE_FILE"; then
        sed -i "s|      - ./rules:/var/ossec/etc/rules/$RULES_SUBDIR:ro|      - ./rules:/var/ossec/etc/rules/$RULES_SUBDIR:ro\n      - ./decoders:/var/ossec/etc/decoders/$RULES_SUBDIR:ro|" \
            "$COMPOSE_FILE"
        log "Added decoders volume mount to docker-compose.yml"
        NEW_MOUNTS=1
    fi
    if ! grep -qF "./lists:/var/ossec/etc/lists/$RULES_SUBDIR" "$COMPOSE_FILE"; then
        sed -i "s|      - ./decoders:/var/ossec/etc/decoders/$RULES_SUBDIR:ro|      - ./decoders:/var/ossec/etc/decoders/$RULES_SUBDIR:ro\n      - ./lists:/var/ossec/etc/lists/$RULES_SUBDIR|" \
            "$COMPOSE_FILE"
        log "Added lists volume mount to docker-compose.yml"
        NEW_MOUNTS=1
    fi
    if grep -qF "./lists:/var/ossec/etc/lists/$RULES_SUBDIR:ro" "$COMPOSE_FILE"; then
        sed -i "s|./lists:/var/ossec/etc/lists/$RULES_SUBDIR:ro|./lists:/var/ossec/etc/lists/$RULES_SUBDIR|" "$COMPOSE_FILE"
        log "Updated lists volume mount to read-write so Wazuh can build CDB files"
        NEW_MOUNTS=1
    fi
fi

# --- 5. Obtain base ossec.conf on host ---
# Priority: existing host file > running container > fresh image extraction.
if [ -f "$OSSEC_CONF_HOST" ]; then
    log "Using existing regional/ossec.conf"
else
    # Detect running manager container
    MANAGER_CONTAINER=$(
        cd "$PROJECT_ROOT/regional" && \
        docker compose ps -q "$MANAGER_SERVICE" 2>/dev/null || true
    )

    if [ -n "$MANAGER_CONTAINER" ]; then
        log "Extracting ossec.conf from running manager container..."
        docker cp "$MANAGER_CONTAINER":/var/ossec/etc/ossec.conf "$OSSEC_CONF_HOST"
    else
        # Extract default config from the image without starting a full container.
        MANAGER_IMAGE=$(grep -A2 "${MANAGER_SERVICE}:" "$COMPOSE_FILE" \
            | grep 'image:' | awk '{print $2}')
        [ -n "$MANAGER_IMAGE" ] || error "Could not determine manager image from docker-compose.yml"
        log "Extracting default ossec.conf from image: $MANAGER_IMAGE"
        docker run --rm --entrypoint cat "$MANAGER_IMAGE" \
            /var/ossec/etc/ossec.conf > "$OSSEC_CONF_HOST" \
            || error "Failed to extract ossec.conf from $MANAGER_IMAGE"
    fi
    log "Saved base ossec.conf to regional/ossec.conf"
fi

# Ensure the host-side ossec.conf is world-readable so the container's
# wazuh process (which may run as a different UID) can open the file.
chmod 644 "$OSSEC_CONF_HOST"

# --- 6. Patch ossec.conf with rule_dir and decoder_dir entries (idempotent) ---
# One <rule_dir> + one <decoder_dir> entry each causes wazuh-analysisd to
# auto-load every .xml in those directories.
OSSEC_CHANGED=""
if ! grep -qF "etc/rules/$RULES_SUBDIR" "$OSSEC_CONF_HOST"; then
    awk -v tag="    <rule_dir>etc/rules/${RULES_SUBDIR}</rule_dir>" \
        '/<\/ruleset>/ && !done { print tag; done=1 } { print }' \
        "$OSSEC_CONF_HOST" > "$TMP_DIR/ossec.p" && cp "$TMP_DIR/ossec.p" "$OSSEC_CONF_HOST"
    log "ossec.conf: added <rule_dir>etc/rules/$RULES_SUBDIR</rule_dir>"
    OSSEC_CHANGED=1
fi
if ! grep -qF "etc/decoders/$RULES_SUBDIR" "$OSSEC_CONF_HOST"; then
    awk -v tag="    <decoder_dir>etc/decoders/${RULES_SUBDIR}</decoder_dir>" \
        '/<\/ruleset>/ && !done { print tag; done=1 } { print }' \
        "$OSSEC_CONF_HOST" > "$TMP_DIR/ossec.p" && cp "$TMP_DIR/ossec.p" "$OSSEC_CONF_HOST"
    log "ossec.conf: added <decoder_dir>etc/decoders/$RULES_SUBDIR</decoder_dir>"
    OSSEC_CHANGED=1
fi
[ -n "$OSSEC_CHANGED" ] && chmod 644 "$OSSEC_CONF_HOST" \
    && log "ossec.conf: $SYNCED_RULES rule file(s) and $SYNCED_DECODERS decoder file(s) will be loaded."
[ -z "$OSSEC_CHANGED" ] \
    && log "ossec.conf: rule_dir and decoder_dir for $RULES_SUBDIR already present — skipping."

# --- 7. Ensure compose has the ossec.conf volume mount (idempotent) ---
if ! grep -qF "./ossec.conf:/var/ossec/etc/ossec.conf" "$COMPOSE_FILE"; then
    sed -i "s|      - ./lists:/var/ossec/etc/lists/$RULES_SUBDIR:ro|      - ./lists:/var/ossec/etc/lists/$RULES_SUBDIR:ro\n      - ./ossec.conf:/var/ossec/etc/ossec.conf:ro|" \
        "$COMPOSE_FILE"
    log "Added ossec.conf volume mount to docker-compose.yml"
    NEW_MOUNTS=1
fi

# --- 8. Apply to running manager ---
if [ -n "$NO_RELOAD" ]; then
    log "--no-reload: changes will be applied on next 'docker compose up'."
    echo "==========================================="
    echo "✅ Rules staged — ready for provisioning."
    echo "==========================================="
    exit 0
fi

MANAGER_CONTAINER=$(
    cd "$PROJECT_ROOT/regional" && \
    docker compose ps -q "$MANAGER_SERVICE" 2>/dev/null || true
)

if [ -z "$MANAGER_CONTAINER" ]; then
    log "Manager is not running — changes will be applied on next start."
    echo "==========================================="
    echo "✅ Rules staged — run ./scripts/start_all.sh to apply."
    echo "==========================================="
    exit 0
fi

if [ -n "$NEW_MOUNTS" ]; then
    # New volume mount(s) require a container recreate to take effect
    log "New volume mount detected — recreating manager container..."
    (cd "$PROJECT_ROOT/regional" && \
        docker compose up -d --force-recreate "$MANAGER_SERVICE")

    # Give Docker a moment to assign the new container ID before polling
    sleep 3

    log "Waiting for manager to become ready (up to 3 min)..."
    RETRIES=36  # 36 × 5 s = 3 minutes
    while true; do
        # Always fetch the current container ID — it changes after --force-recreate
        MANAGER_CONTAINER=$(
            cd "$PROJECT_ROOT/regional" && \
            docker compose ps -q "$MANAGER_SERVICE" 2>/dev/null || true
        )
        if [ -n "$MANAGER_CONTAINER" ] && \
           docker exec "$MANAGER_CONTAINER" \
               /var/ossec/bin/wazuh-control status 2>/dev/null | \
               grep -q 'wazuh-analysisd is running'; then
            break
        fi
        RETRIES=$((RETRIES - 1))
        [ "$RETRIES" -gt 0 ] || error "Manager did not become ready in time. Check: docker logs $MANAGER_CONTAINER"
        printf "."
        sleep 5
    done
    echo ""
else
    # Rules files changed — a reload is sufficient, no restart needed
    log "Reloading Wazuh manager (hot reload, no restart)..."
    docker exec "$MANAGER_CONTAINER" /var/ossec/bin/wazuh-control reload
fi

# --- 9. Verify ---
log "Manager status:"
docker exec "$MANAGER_CONTAINER" /var/ossec/bin/wazuh-control status \
    | grep -E 'analysisd|remoted' | while IFS= read -r line; do
        printf "  %s\n" "$line"
    done

echo "==========================================="
echo "✅ SOCFortress rules are active."
echo "   Dashboard → Management → Rules → Filter: group:socfortress"
echo "==========================================="
