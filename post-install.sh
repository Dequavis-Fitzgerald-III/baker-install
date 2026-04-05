#!/bin/bash
# =============================================================================
# Arch Linux Post-Install Script
# Run this after first boot as your regular user (not root).
# It reads config written by install.sh from ~/.install-config
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
# LOAD CONFIG written by install.sh
# =============================================================================
CONFIG_FILE="$HOME/.install-config"
[[ ! -f "$CONFIG_FILE" ]] && error "Config file not found at $CONFIG_FILE"

# Source the config — this loads USERNAME, PROFILE, DOTFILES_URL, TIMEZONE
# into our environment as variables.
source "$CONFIG_FILE"
success "Loaded install config"
info "Profile: $PROFILE | User: $USERNAME | Dotfiles: $DOTFILES_URL"

# Make sure we're not running as root — this script should run as the user.
[[ "$EUID" -eq 0 ]] && error "Don't run this as root. Run as $USERNAME."

# =============================================================================
# SECTION 1 — SSH SETUP
# Generate an SSH key and add it to GitHub before anything else.
# We need SSH working before we can clone private repos or push/pull.
# =============================================================================
section "Setting up SSH"

SSH_KEY="$HOME/.ssh/id_ed25519"

if [[ -f "$SSH_KEY" ]]; then
    warn "SSH key already exists at $SSH_KEY, skipping generation"
else
    # Generate an ed25519 SSH key — more secure and shorter than RSA.
    # -t = key type, -C = comment (just a label, usually your email),
    # -f = output file, -N "" = no passphrase on the key itself
    ssh-keygen -t ed25519 -C "$USERNAME@$HOSTNAME" -f "$SSH_KEY" -N ""
    success "SSH key generated at $SSH_KEY"
fi

# Start the SSH agent — this holds your key in memory so you don't have
# to re-enter a passphrase every time you use git.
eval "$(ssh-agent -s)"
ssh-add "$SSH_KEY"
success "SSH key added to agent"

# Print the public key so you can copy it to GitHub.
echo ""
echo "============================================"
echo "  Add this SSH key to GitHub before continuing:"
echo "  github.com → Settings → SSH and GPG keys → New SSH key"
echo "============================================"
echo ""
cat "$SSH_KEY.pub"
echo ""
read -rp "Press ENTER once you've added the key to GitHub..."

# Test the connection to GitHub to confirm the key is working.
# We use || true because ssh returns exit code 1 even on success here.
ssh -T git@github.com 2>&1 | grep -q "successfully authenticated" \
    || warn "Could not verify GitHub connection — continuing anyway. Check your key if clones fail."
success "SSH setup complete"

# Tell git to always use SSH instead of HTTPS for github.com.
# This means even HTTPS URLs get rewritten to SSH automatically.
# So 'git clone https://github.com/...' becomes 'git clone git@github.com:...'
git config --global url."git@github.com:".insteadOf "https://github.com/"
success "Git configured to use SSH for all GitHub interactions"

# =============================================================================
# SECTION 2 — YAY (AUR Helper)
# yay lets us install packages from the AUR (Arch User Repository).
# The AUR has packages not in the official repos — like google-chrome.
# We build yay from source using git and makepkg.
# =============================================================================
section "Installing yay (AUR helper)"

if command -v yay &> /dev/null; then
    warn "yay already installed, skipping"
else
    cd /tmp
    # Clone the yay PKGBUILD from AUR
    git clone https://aur.archlinux.org/yay.git
    cd yay
    # makepkg builds and installs the package.
    # -s = install dependencies, -i = install after build, --noconfirm = no prompts
    makepkg -si --noconfirm
    cd ~
    success "yay installed"
fi

# =============================================================================
# SECTION 3 — AUR PACKAGES
# These are packages not in the official Arch repos, installed via yay.
# =============================================================================
section "Installing AUR packages"

AUR_PACKAGES=(
    google-chrome        # Browser
    nordvpn-bin          # NordVPN client (binary, no compile needed)
    jetbrains-toolbox    # JetBrains IDE manager (PyCharm, etc.)
)

# yay works just like pacman for installing — same flags.
yay -S --noconfirm "${AUR_PACKAGES[@]}"
success "AUR packages installed"

# =============================================================================
# SECTION 4 — FLATPAK PACKAGES
# Flatpak apps are sandboxed and cross-distro.
# We add Flathub (the main Flatpak repo) first.
# =============================================================================
section "Installing Flatpak packages"

FLATPAK_PACKAGES=(
    com.spotify.Client    # Spotify music player
)

# Add Flathub remote — --if-not-exists prevents an error if already added.
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

for pkg in "${FLATPAK_PACKAGES[@]}"; do
    flatpak install -y flathub "$pkg"
done

success "Flatpak packages installed"

# =============================================================================
# SECTION 5 — PROJECTS FOLDER & REPOS
# Create ~/projects and clone both baker-install and dotfiles into it.
# Keeping everything in ~/projects makes it easy to find and back up.
# SSH is now set up so these clones will authenticate correctly.
# =============================================================================
section "Setting up ~/projects directory"

mkdir -p "$HOME/projects"
success "~/projects directory created"

mkdir -p "$HOME/.venvs"
success "~/.venvs directory created"

# Clone baker-install (this repo — useful to have on every machine)
BAKER_INSTALL_DIR="$HOME/projects/baker-install"
if [[ -d "$BAKER_INSTALL_DIR/.git" ]]; then
    warn "baker-install already exists, pulling latest..."
    git -C "$BAKER_INSTALL_DIR" pull
else
    git clone git@github.com:Dequavis-Fitzgerald-III/baker-install.git "$BAKER_INSTALL_DIR"
    success "baker-install cloned to $BAKER_INSTALL_DIR"
fi

# Clone dotfiles into ~/projects/dotfiles
DOTFILES_DIR="$HOME/projects/dotfiles"

if [[ -d "$DOTFILES_DIR/.git" ]]; then
    warn "Dotfiles already exists, pulling latest..."
    git -C "$DOTFILES_DIR" pull
else
    git clone "$DOTFILES_URL" "$DOTFILES_DIR"
    success "Dotfiles cloned to $DOTFILES_DIR"
fi

# Helper function to create a symlink safely.
# If the target already exists (and isn't a symlink), we back it up first.
symlink() {
    local src="$1"   # file in dotfiles repo
    local dst="$2"   # where the app expects it

    # Create parent directory if it doesn't exist
    mkdir -p "$(dirname "$dst")"

    if [[ -e "$dst" && ! -L "$dst" ]]; then
        warn "Backing up existing $dst to $dst.bak"
        mv "$dst" "$dst.bak"
    fi

    ln -sf "$src" "$dst"
    success "Linked $src → $dst"
}

# Symlink each config file.
# If your dotfiles repo structure changes, update these paths.
symlink "$DOTFILES_DIR/bash/.bashrc"               "$HOME/.bashrc"
symlink "$DOTFILES_DIR/kitty/kitty.conf"           "$HOME/.config/kitty/kitty.conf"
symlink "$DOTFILES_DIR/hypr/hyprland.conf"         "$HOME/.config/hypr/hyprland.conf"

success "Dotfiles symlinked"

# =============================================================================
# SECTION 6 — NORDVPN
# nordvpn-bin installs the NordVPN daemon. We need to:
# 1. Create the nordvpn group (the installer may do this, but we ensure it)
# 2. Add our user to the nordvpn group so we can run nordvpn commands
# 3. Enable and start the daemon
# Note: Login and autoconnect must be done manually after reboot as group
# membership only takes effect after re-login.
# =============================================================================
section "Setting up NordVPN"

# Create nordvpn group if it doesn't exist.
# -f means don't error if the group already exists.
sudo groupadd -f nordvpn
success "nordvpn group ensured"

# Add user to nordvpn group.
# -aG means append to group without removing from other groups.
sudo usermod -aG nordvpn "$USERNAME"
success "$USERNAME added to nordvpn group"

# Enable and start the daemon.
# --now means enable AND start immediately rather than just on next boot.
sudo systemctl enable --now nordvpnd
success "nordvpnd service enabled and started"

# =============================================================================
# SECTION 7 — SET LOCALE
# Set the system locale via localectl.
# This persists across reboots (writes to /etc/locale.conf).
# =============================================================================
section "Setting locale"

sudo localectl set-locale LANG=en_GB.UTF-8
success "Locale set to en_GB.UTF-8"

sudo timedatectl set-timezone "$TIMEZONE"
success "Timezone set to $TIMEZONE"

# =============================================================================
# SECTION 8 — ENABLE REMAINING SERVICES
# Some services are better enabled after first boot with the full system running.
# =============================================================================
section "Enabling services"

# These should already be enabled from chroot, but we ensure them here too.
sudo systemctl enable --now NetworkManager
sudo systemctl enable --now sddm
sudo systemctl enable --now ufw

# Pipewire is a user service — it runs per-user, not system-wide.
# systemctl --user manages services in the user session.
systemctl --user enable --now pipewire
systemctl --user enable --now pipewire-pulse
systemctl --user enable --now wireplumber
success "Pipewire user services enabled"

# Profile-specific services
if [[ "$PROFILE" == "laptop" ]]; then
    sudo systemctl enable --now tlp
    sudo systemctl enable --now bluetooth
    success "Laptop services enabled (tlp, bluetooth)"
fi

success "All services enabled"

# =============================================================================
# DONE
# =============================================================================
section "Post-install complete!"
echo ""
echo "============================================"
echo "  Things to do manually after this script:"
echo "============================================"
echo "  1. Reboot:                    sudo reboot"
echo "  2. Log in to NordVPN:         nordvpn login"
echo "  3. Set NordVPN autoconnect:   nordvpn set autoconnect enabled us"
echo ""
if [[ "$PROFILE" == "laptop" ]]; then
    echo "  4. See TEMP_JARVIS_DEV_SETUP.md in ~/projects/baker-install"
    echo "     if you need to set up the Jarvis dev environment"
    echo ""
fi
echo "Enjoy your fresh Arch install! 🚀"
echo ""

# Self-delete — remove this script from the home directory now it's done.
rm -- "$0"
