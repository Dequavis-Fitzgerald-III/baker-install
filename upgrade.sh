#!/bin/bash
# =============================================================================
# Baker Upgrade Script
# Converges a running baker machine to the current desired state.
# Safe to run at any time — all steps are idempotent.
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

BAKER_DIR="$HOME/projects/baker"
BAKER_CONFIG="$HOME/.baker-config"

[[ ! -d "$BAKER_DIR/.git" ]] && error "Baker repo not found at $BAKER_DIR. Is this a baker machine?"
[[ ! -f "$BAKER_CONFIG" ]]   && error ".baker-config not found at $BAKER_CONFIG. Is this a baker machine?"

section "Pulling latest baker repo"
git -C "$BAKER_DIR" pull
success "Baker repo up to date"

source "$BAKER_CONFIG"
info "Profile: $PROFILE | GPU: $GPU"

# Extracts a named [section] block from manifest content piped via stdin.
parse_section() {
    awk "/^\[$1\]/{found=1; next} /^\[/{found=0} found && !/^#/ && NF"
}

# =============================================================================
# SECTION 1 — SYSTEM UPGRADE
# =============================================================================
section "Upgrading system packages"
sudo pacman -Syu --noconfirm
success "System packages upgraded"

# =============================================================================
# SECTION 2 — PACMAN PACKAGES
# --needed skips packages already installed — safe to run on a live system.
# =============================================================================
section "Installing missing pacman packages"
mapfile -t PACMAN_PACKAGES < <(
    parse_section pacman < "$BAKER_DIR/packages/base.txt"
    parse_section pacman < "$BAKER_DIR/packages/$PROFILE.txt"
)
sudo pacman -S --needed --noconfirm "${PACMAN_PACKAGES[@]}"
success "Pacman packages up to date"

# =============================================================================
# SECTION 3 — AUR PACKAGES
# =============================================================================
section "Installing missing AUR packages"
mapfile -t AUR_PACKAGES < <(parse_section aur < "$BAKER_DIR/packages/base.txt")
yay -S --needed --noconfirm "${AUR_PACKAGES[@]}"
success "AUR packages up to date"

# =============================================================================
# SECTION 4 — FLATPAK PACKAGES
# =============================================================================
section "Installing missing Flatpak packages"
mapfile -t FLATPAK_PACKAGES < <(parse_section flatpak < "$BAKER_DIR/packages/base.txt")
for pkg in "${FLATPAK_PACKAGES[@]}"; do
    flatpak install -y --noninteractive flathub "$pkg" || true
done
success "Flatpak packages up to date"

# =============================================================================
# SECTION 5 — DOTFILES
# =============================================================================
section "Updating dotfiles"

DOTFILES_DIR="$HOME/projects/dotfiles"

# Creates a symlink from dst (where the app looks) to src (file in dotfiles repo).
# Backs up any existing real file at dst before overwriting.
symlink() {
    local src="$1"
    local dst="$2"
    mkdir -p "$(dirname "$dst")"
    if [[ -e "$dst" && ! -L "$dst" ]]; then
        warn "Backing up existing $dst to $dst.bak"
        mv "$dst" "$dst.bak"
    fi
    ln -sf "$src" "$dst"
    success "Linked $src → $dst"
}

# Pull the dotfiles repo (separate from the baker repo pulled at the top)
git -C "$DOTFILES_DIR" pull
symlink "$DOTFILES_DIR/bash/.bashrc"               "$HOME/.bashrc"
symlink "$DOTFILES_DIR/kitty/kitty.conf"           "$HOME/.config/kitty/kitty.conf"
symlink "$DOTFILES_DIR/hypr/hyprland.conf"         "$HOME/.config/hypr/hyprland.conf"
symlink "$DOTFILES_DIR/waybar"                     "$HOME/.config/waybar"
hyprctl reload 2>/dev/null || true
success "Dotfiles up to date"

# =============================================================================
# SECTION 6 — SERVICES
# systemctl enable --now is a no-op if the service is already enabled and running.
# =============================================================================
section "Ensuring services are enabled"
sudo systemctl enable --now NetworkManager
sudo systemctl enable --now sddm
sudo systemctl enable --now ufw
sudo systemctl enable --now sshd
sudo systemctl enable --now tailscaled
sudo systemctl enable --now nordvpnd
systemctl --user enable --now pipewire
systemctl --user enable --now pipewire-pulse
systemctl --user enable --now wireplumber
if [[ "$PROFILE" == "laptop" ]]; then
    sudo systemctl enable --now tlp
    sudo systemctl enable --now bluetooth
fi
success "Services up to date"

# =============================================================================
# SECTION 7 — SSH CONFIG REBUILD
# =============================================================================
section "Rebuilding SSH config from baker key registry"
bash "$BAKER_DIR/sync-baker-keys.sh"
success "SSH config up to date"

# =============================================================================
# DONE
# =============================================================================
section "Upgrade complete"
success "BakerOS is up to date"
