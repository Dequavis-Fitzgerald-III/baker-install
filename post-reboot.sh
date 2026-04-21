#!/bin/bash
# =============================================================================
# Arch Linux Post-Reboot Script
# Run this after the reboot at the end of post-install.sh
# github.com/Dequavis-Fitzgerald-III
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
section() { echo -e "\n${BOLD}=== $1 ===${NC}\n"; }

# =============================================================================
# SECTION 1 — NORDVPN
# Group membership from post-install is active after reboot so nordvpn
# commands work without any newgrp gymnastics.
# nordvpn login opens a browser auth flow — we can't automate this.
# We wait for the user to confirm before setting autoconnect and killswitch
# so those commands don't run against an unauthenticated client.
# =============================================================================
section "NordVPN Setup"

info "Launching NordVPN login — your browser will open to complete auth..."
nordvpn login || warn "nordvpn login failed — run it manually before continuing"

read -rp "Press ENTER once you have logged in to NordVPN in the browser..."

nordvpn set autoconnect on us || warn "Failed to set autoconnect — try manually: nordvpn set autoconnect on us"
nordvpn set killswitch on     || warn "Failed to set killswitch — try manually: nordvpn set killswitch on"
success "NordVPN autoconnect (us) and killswitch enabled"

# =============================================================================
# SECTION 2 — BASHRC ADDITIONS
# We append to .bashrc rather than symlinking here because these are
# machine-specific behaviours, not dotfile config.
# We guard each addition with a grep check so re-running this script
# doesn't duplicate lines.
# =============================================================================
section "Configuring .bashrc"

BASHRC="$HOME/.bashrc"

# PyCharm venv discovery — tells PyCharm where to look for virtualenvs
if ! grep -q "WORKON_HOME" "$BASHRC"; then
    echo '' >> "$BASHRC"
    echo '# PyCharm venv discovery' >> "$BASHRC"
    echo 'export WORKON_HOME="$HOME/.venvs"' >> "$BASHRC"
    success "WORKON_HOME added to .bashrc"
else
    warn "WORKON_HOME already in .bashrc, skipping"
fi

# Todo checklist hook — displays ~/.todo if it exists
if ! grep -q "\.todo" "$BASHRC"; then
    echo '' >> "$BASHRC"
    cat >> "$BASHRC" <<'TODOHOOK'
# Show todo checklist until manually cleared
if [[ -f "$HOME/.todo" ]]; then
    echo ""
    echo -e "\033[1;33m=== TODO ===\033[0m"
    cat "$HOME/.todo"
    echo -e "\033[1;33m============\033[0m"
    echo ""
fi
TODOHOOK
    success "Todo hook added to .bashrc"
else
    warn "Todo hook already in .bashrc, skipping"
fi

# =============================================================================
# SECTION 3 — TODO FILE
# Written to ~/.todo and displayed on every new terminal via the hook above.
# User clears it manually once everything is done by running: rm ~/.todo
# =============================================================================
section "Writing todo checklist"

cat > "$HOME/.todo" <<TODO
  [ ] Set Chrome download location: Settings → Downloads → ~/downloads
  [ ] On any other baker machines already installed: bash ~/projects/baker/sync-baker-keys.sh
  [ ] Clear this list: rm ~/.todo
TODO
success "Todo checklist written to ~/.todo"
info "It will display on every new terminal until you run: rm ~/.todo"

# =============================================================================
# DONE — self-delete
# =============================================================================
section "Post-reboot setup complete!"
echo ""
success "Everything is configured. Open a new terminal to see your todo list."
echo ""

rm -- "$0"
