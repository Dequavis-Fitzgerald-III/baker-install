#!/bin/bash
# =============================================================================
# Baker Machine Key Sync
# Run this on existing baker machines after a new machine has been installed
# and its public key pushed to the baker repo. Pulls the latest keys
# and rebuilds authorized_keys + ~/.ssh/config from the registry.
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

BAKER_INSTALL_DIR="$HOME/projects/baker"
KEYS_DIR="$BAKER_INSTALL_DIR/keys"
SSH_KEY="$HOME/.ssh/id_ed25519"
CURRENT_HOST="$(cat /etc/hostname)"
USERNAME="$(whoami)"

[[ -d "$BAKER_INSTALL_DIR/.git" ]] || error "baker repo not found at $BAKER_INSTALL_DIR"

# Pull latest keys from the repo
info "Pulling latest keys from baker repo..."
git -C "$BAKER_INSTALL_DIR" pull
success "Repo updated"

# Rebuild authorized_keys from all keys in the registry
AUTH_KEYS="$HOME/.ssh/authorized_keys"
touch "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"

for pubkey_file in "$KEYS_DIR"/*.pub; do
    [[ -f "$pubkey_file" ]] || continue
    key_content="$(cat "$pubkey_file")"
    if ! grep -qxF "$key_content" "$AUTH_KEYS" 2>/dev/null; then
        echo "$key_content" >> "$AUTH_KEYS"
        success "Authorized: $(basename "$pubkey_file" .pub)"
    fi
done

# Rebuild ~/.ssh/config baker machine block
SSH_CONFIG="$HOME/.ssh/config"
touch "$SSH_CONFIG"
chmod 600 "$SSH_CONFIG"

MARKER_START="# BEGIN baker machines"
MARKER_END="# END baker machines"

if grep -q "$MARKER_START" "$SSH_CONFIG" 2>/dev/null; then
    sed -i "/$MARKER_START/,/$MARKER_END/d" "$SSH_CONFIG"
fi

{
    echo ""
    echo "$MARKER_START"
    for pubkey_file in "$KEYS_DIR"/*.pub; do
        [[ -f "$pubkey_file" ]] || continue
        machine="$(basename "$pubkey_file" .pub)"
        [[ "$machine" == "$CURRENT_HOST" ]] && continue
        printf '\nHost %s\n    Hostname %s\n    User %s\n    IdentityFile %s\n' \
            "$machine" "$machine" "$USERNAME" "$SSH_KEY"
    done
    echo ""
    echo "$MARKER_END"
} >> "$SSH_CONFIG"

success "~/.ssh/config updated with baker machine entries"
info "Run on all other baker machines to sync their access too"
