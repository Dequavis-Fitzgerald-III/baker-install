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

# Source the config — loads USERNAME, PROFILE, DOTFILES_URL, TIMEZONE
source "$CONFIG_FILE"
success "Loaded install config"
info "Profile: $PROFILE | User: $USERNAME | Dotfiles: $DOTFILES_URL"

# Make sure we're not running as root.
[[ "$EUID" -eq 0 ]] && error "Don't run this as root. Run as $USERNAME."

# =============================================================================
# SECTION 1 — NETWORK CHECK
# NetworkManager should be up from the enabled service, but we verify
# connectivity before anything else tries to hit the internet.
# On laptop we offer to connect via nmcli if not already online.
# =============================================================================
section "Network Check"

if ping -c 1 -W 5 archlinux.org > /dev/null 2>&1; then
    success "Internet connection confirmed"
else
    warn "No internet detected."
    if [[ "$PROFILE" == "laptop" ]]; then
        info "Attempting wifi connection via NetworkManager..."
        read -rp "SSID (wifi network name): " WIFI_SSID
        read -rsp "Wifi password: " WIFI_PASSWORD
        echo ""
        # nmcli is the NetworkManager command line tool.
        # 'device wifi connect' connects to an SSID with a password.
        nmcli device wifi connect "$WIFI_SSID" password "$WIFI_PASSWORD" \
            || error "Failed to connect. Check SSID and password."
        sleep 3
        ping -c 1 -W 5 archlinux.org > /dev/null 2>&1 \
            || error "Still no internet after wifi connect. Check connection and retry."
        success "Connected to $WIFI_SSID"
    else
        error "No internet on workstation. Check your ethernet connection and retry."
    fi
fi

# =============================================================================
# SECTION 2 — YAY (AUR Helper)
# yay lets us install packages from the AUR (Arch User Repository).
# We build it from source using git and makepkg — the standard AUR method.
# =============================================================================
section "Installing yay (AUR helper)"

if command -v yay &> /dev/null; then
    warn "yay already installed, skipping"
else
    cd /tmp
    git clone https://aur.archlinux.org/yay.git
    cd yay
    # -s = install dependencies, -i = install after build, --noconfirm = no prompts
    makepkg -si --noconfirm
    cd ~
    success "yay installed"
fi

# =============================================================================
# SECTION 3 — AUR PACKAGES
# Packages not in the official Arch repos, installed via yay.
# =============================================================================
section "Installing AUR packages"

AUR_PACKAGES=(
    google-chrome        # Browser
    nordvpn-bin          # NordVPN client (binary, no compile needed)
    jetbrains-toolbox    # JetBrains IDE manager (PyCharm, etc.)
)

yay -S --noconfirm "${AUR_PACKAGES[@]}"
success "AUR packages installed"

# =============================================================================
# SECTION 4 — CHROME FLAGS
# Tell Chrome to use its own built-in password store rather than asking
# for a system keyring. Prevents the "choose password for new keyring"
# prompt on first launch. Safe with LUKS — disk is already encrypted at rest.
# =============================================================================
section "Configuring Chrome"

mkdir -p "$HOME/.config"
echo "--password-store=basic" > "$HOME/.config/chrome-flags.conf"
success "Chrome configured to use built-in password store (no keyring prompt)"

# =============================================================================
# SECTION 5 — FLATPAK PACKAGES
# Flatpak apps are sandboxed. We add Flathub (the main repo) first.
# =============================================================================
section "Installing Flatpak packages"

FLATPAK_PACKAGES=(
    com.spotify.Client
)

flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

for pkg in "${FLATPAK_PACKAGES[@]}"; do
    flatpak install -y flathub "$pkg"
done

success "Flatpak packages installed"

# =============================================================================
# SECTION 6 — HOME DIRECTORY SETUP
# Create standard directories and clone repos over HTTPS.
#
# We use HTTPS for ALL clones here — no SSH key is needed for public repos
# and it avoids any dependency on the key being set up yet.
# SSH setup happens at the very end of this script once you're at a working
# desktop and can easily copy the key.
# =============================================================================
section "Setting up home directory"

mkdir -p "$HOME/documents"
mkdir -p "$HOME/downloads"
mkdir -p "$HOME/projects"
mkdir -p "$HOME/.venvs"
success "Home directories created"

# Clone baker-install (over HTTPS — no SSH key needed)
BAKER_INSTALL_DIR="$HOME/projects/baker-install"
if [[ -d "$BAKER_INSTALL_DIR/.git" ]]; then
    warn "baker-install already exists, pulling latest..."
    git -C "$BAKER_INSTALL_DIR" pull
else
    git clone https://github.com/Dequavis-Fitzgerald-III/baker-install.git "$BAKER_INSTALL_DIR"
    success "baker-install cloned to $BAKER_INSTALL_DIR"
fi

# Clone dotfiles (over HTTPS — no SSH key needed)
DOTFILES_DIR="$HOME/projects/dotfiles"
if [[ -d "$DOTFILES_DIR/.git" ]]; then
    warn "Dotfiles already exists, pulling latest..."
    git -C "$DOTFILES_DIR" pull
else
    git clone "$DOTFILES_URL" "$DOTFILES_DIR"
    success "Dotfiles cloned to $DOTFILES_DIR"
fi

# Helper function to create a symlink safely.
# If the target already exists and isn't already a symlink, we back it up.
symlink() {
    local src="$1"   # file in the dotfiles repo
    local dst="$2"   # where the app expects it to be

    mkdir -p "$(dirname "$dst")"

    if [[ -e "$dst" && ! -L "$dst" ]]; then
        warn "Backing up existing $dst to $dst.bak"
        mv "$dst" "$dst.bak"
    fi

    ln -sf "$src" "$dst"
    success "Linked $src → $dst"
}

symlink "$DOTFILES_DIR/bash/.bashrc"               "$HOME/.bashrc"
symlink "$DOTFILES_DIR/kitty/kitty.conf"           "$HOME/.config/kitty/kitty.conf"
symlink "$DOTFILES_DIR/hypr/hyprland.conf"         "$HOME/.config/hypr/hyprland.conf"
success "Dotfiles symlinked"

sleep 1
hyprctl reload || true
success "Hyprland config reloaded"

# =============================================================================
# SECTION 7 — NORDVPN
# nordvpn-bin installs the daemon. We create the group, add the user,
# and start the service. Login and autoconnect are manual steps after reboot
# because group membership only takes effect after re-login.
# =============================================================================
section "Setting up NordVPN"

sudo groupadd -f nordvpn
sudo usermod -aG nordvpn "$USERNAME"
sudo systemctl enable --now nordvpnd
success "NordVPN configured (login manually after reboot: nordvpn login)"

# =============================================================================
# SECTION 8 — LOCALE & TIMEZONE (ensure correct via localectl)
# These were set in chroot but we confirm them here via localectl/timedatectl
# which write to the live system config and persist across reboots.
# =============================================================================
section "Confirming locale and timezone"

sudo localectl set-locale LANG=en_GB.UTF-8
success "Locale confirmed: en_GB.UTF-8"

sudo timedatectl set-timezone "$TIMEZONE"
success "Timezone confirmed: $TIMEZONE"

# =============================================================================
# SECTION 9 — SERVICES
# Most services were enabled in chroot. We ensure them here and add
# the per-user pipewire services which can only run in a user session.
# =============================================================================
section "Enabling services"

sudo systemctl enable --now NetworkManager
sudo systemctl enable --now sddm
sudo systemctl enable --now ufw

# Pipewire runs as a user service (per-session, not system-wide).
# systemctl --user manages the current user's session services.
systemctl --user enable --now pipewire
systemctl --user enable --now pipewire-pulse
systemctl --user enable --now wireplumber
success "Pipewire user services enabled"

if [[ "$PROFILE" == "laptop" ]]; then
    sudo systemctl enable --now tlp
    sudo systemctl enable --now bluetooth
    success "Laptop services enabled (tlp, bluetooth)"
fi

success "All services enabled"

# =============================================================================
# SECTION 10 — SSH SETUP
# This is the last step intentionally.
#
# Everything above used HTTPS so no key was needed. Now that you have a
# working desktop, generate your SSH key and add it to GitHub directly
# from this terminal — no second device required, just copy and paste.
#
# After the key is on GitHub we set a git URL rewrite rule so all future
# git operations automatically use SSH instead of HTTPS. You won't need
# to change any remote URLs manually.
# =============================================================================
section "SSH Setup"

SSH_KEY="$HOME/.ssh/id_ed25519"

if [[ -f "$SSH_KEY" ]]; then
    warn "SSH key already exists at $SSH_KEY, skipping generation"
else
    # ed25519 is more secure and produces shorter keys than RSA.
    # -C is just a label (comment) to identify the key on GitHub.
    # -N "" means no passphrase on the key file itself.
    ssh-keygen -t ed25519 -C "$(whoami)@$(hostname)" -f "$SSH_KEY" -N ""
    success "SSH key generated"
fi

# Start the SSH agent and load the key into it.
# The agent holds the key in memory so git doesn't prompt repeatedly.
eval "$(ssh-agent -s)"
ssh-add "$SSH_KEY"
success "SSH key added to agent"

# Print the public key — copy this into GitHub.
echo ""
echo "============================================================"
echo "  Copy the key below and add it to GitHub:"
echo "  github.com → Settings → SSH and GPG keys → New SSH key"
echo "============================================================"
echo ""
cat "$SSH_KEY.pub"
echo ""
read -rp "Press ENTER once you've added the key to GitHub..."

# Verify the connection. SSH to GitHub returns exit code 1 even on success
# (it prints a greeting and disconnects), so we check the output text instead.
SSH_TEST=$(ssh -T git@github.com 2>&1 || true)
if echo "$SSH_TEST" | grep -q "successfully authenticated"; then
    success "GitHub SSH connection verified"
else
    warn "Could not verify GitHub SSH connection. Output was: $SSH_TEST"
    warn "Continuing anyway — check your key if git push/pull fails later."
fi

# Set git to rewrite all github.com HTTPS URLs to SSH automatically.
# This means 'git clone https://github.com/...' and 'git pull' etc. all
# go through SSH from this point on, without changing any remote URLs.
git config --global url."git@github.com:".insteadOf "https://github.com/"
success "Git configured to use SSH for all GitHub interactions"

# Update the remote URLs on the repos we already cloned over HTTPS,
# so push/pull on those repos also goes through SSH going forward.
git -C "$HOME/projects/dotfiles" remote set-url origin "git@github.com:${DOTFILES_URL#https://github.com/}"
git -C "$HOME/projects/baker-install" remote set-url origin "git@github.com:Dequavis-Fitzgerald-III/baker-install.git"
success "Remote URLs updated to SSH on existing repos"

# =============================================================================
# DONE
# =============================================================================
section "Post-install complete!"
echo ""
echo "============================================================"
echo "  Things to do manually:"
echo "============================================================"
echo "  1. Reboot:                         sudo reboot"
echo "  2. Log in to NordVPN:              nordvpn login"
echo "  3. Set NordVPN autoconnect:        nordvpn set autoconnect enabled us"
echo "  4. Set Chrome download location:   Settings → Downloads → ~/downloads"
echo "  5. Set PyCharm projects location:  Toolbox → Settings → ~/projects"
echo "  6. Set PyCharm venv location:      Settings → Tools → Python Integrated Tools → ~/.venvs"
echo ""
if [[ "$PROFILE" == "laptop" ]]; then
    echo "  See TEMP_JARVIS_DEV_SETUP.md in ~/projects/baker-install"
    echo "  if you need to set up the Jarvis dev environment."
    echo ""
fi
echo "Enjoy your fresh Arch install!"
echo ""

# Self-delete — remove this script and .install-config from the home directory now it's done.
rm -f "$HOME/.install-config"
rm -- "$0"
