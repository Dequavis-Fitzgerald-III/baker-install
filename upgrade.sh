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
# Default editable keys that may be missing from older .baker-config files
LOCALE="${LOCALE:-en_GB.UTF-8}"
KEYMAP="${KEYMAP:-us}"
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
# SECTION 8 — SYNC .baker-config
# Re-detects hardware values from the live system and rewrites .baker-config
# in canonical format. Editable values are preserved from the current file.
# =============================================================================
section "Syncing .baker-config"

# GPU — check loaded modules first, fall back to lspci
if lsmod | grep -q "^nvidia " || lspci | grep -qi "vga.*nvidia"; then
    DETECTED_GPU="nvidia"
elif lsmod | grep -q "^amdgpu " || lspci | grep -qi "vga.*amd\|vga.*radeon"; then
    DETECTED_GPU="amd"
elif lsmod | grep -q "^i915 " || lspci | grep -qi "vga.*intel"; then
    DETECTED_GPU="intel"
else
    DETECTED_GPU="none"
fi

# LUKS — check if root filesystem sits on a crypt device
ROOT_SOURCE=$(findmnt -n -o SOURCE /)
ROOT_FS_TYPE=$(lsblk -no TYPE "$ROOT_SOURCE" 2>/dev/null)
if [[ "$ROOT_FS_TYPE" == "crypt" ]]; then
    DETECTED_LUKS=true
    CRYPT_DEVICE=$(cryptsetup status cryptroot 2>/dev/null | awk '/device:/ {print $2}')
    DETECTED_LUKS_UUID=$(sudo blkid -s UUID -o value "$CRYPT_DEVICE" 2>/dev/null)
else
    DETECTED_LUKS=false
    DETECTED_LUKS_UUID=""
fi

# DUAL_BOOT — check for Windows EFI files on the EFI partition
EFI_DIR=$(findmnt -n -o TARGET /boot/efi 2>/dev/null || findmnt -n -o TARGET /boot 2>/dev/null)
if ls "${EFI_DIR}/EFI/" 2>/dev/null | grep -qi "microsoft"; then
    DETECTED_DUAL_BOOT=true
else
    DETECTED_DUAL_BOOT=false
fi

# HDD — check if the stored HDD_MOUNT is still present in fstab
if [[ -n "$HDD_MOUNT" ]] && grep -qE "^\S+\s+${HDD_MOUNT}\s+" /etc/fstab; then
    DETECTED_HDD=true
    DETECTED_HDD_MOUNT="$HDD_MOUNT"
else
    DETECTED_HDD=false
    DETECTED_HDD_MOUNT=""
fi

cat > "$BAKER_CONFIG" <<BAKERCONF
# =============================================================================
# BakerOS Machine Configuration — ~/.baker-config
# Edit values under SYSTEM CONFIG and run baker-update to apply.
# Values under HARDWARE are auto-detected — edits will be reset on next update.
# =============================================================================

# --- System Config (editable) ---
HOSTNAME=$HOSTNAME
TIMEZONE=$TIMEZONE
LOCALE=$LOCALE
KEYMAP=$KEYMAP
DOTFILES_URL=$DOTFILES_URL

# --- Hardware (auto-detected, do not edit) ---
USERNAME=$USERNAME
PROFILE=$PROFILE
GPU=$DETECTED_GPU
BAKERCONF

if [[ "$DETECTED_LUKS" == true ]]; then
    printf "LUKS=true\nLUKS_UUID=%s\n" "$DETECTED_LUKS_UUID" >> "$BAKER_CONFIG"
else
    echo "LUKS=false" >> "$BAKER_CONFIG"
fi

echo "DUAL_BOOT=$DETECTED_DUAL_BOOT" >> "$BAKER_CONFIG"

if [[ "$DETECTED_HDD" == true ]]; then
    printf "HDD=true\nHDD_MOUNT=%s\n" "$DETECTED_HDD_MOUNT" >> "$BAKER_CONFIG"
else
    echo "HDD=false" >> "$BAKER_CONFIG"
fi

success ".baker-config synced"

# =============================================================================
# SECTION 9 — SYSTEM CONFIGURATION
# Applies idempotent system config from the freshly synced .baker-config.
# Only makes changes if something has drifted from the desired state.
# =============================================================================
section "Applying system configuration"
sudo bash "$BAKER_DIR/configure.sh" "$HOME/.baker-config"
success "System configuration up to date"

# =============================================================================
# DONE
# =============================================================================
section "Upgrade complete"
success "BakerOS is up to date"
