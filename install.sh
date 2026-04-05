#!/bin/bash
# =============================================================================
# Arch Linux Install Script
# Generic, interactive installer for Workstation and Laptop profiles
# github.com/Dequavis-Fitzgerald-III
# =============================================================================

# Exit immediately if any command fails.
# This is critical in an install script — if partitioning fails, we don't want
# to carry on and make things worse.
set -e

# -----------------------------------------------------------------------------
# COLOURS — just makes the output easier to read during a long install
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Colour

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
section() { echo -e "\n${BOLD}=== $1 ===${NC}\n"; }

# =============================================================================
# SECTION 1 — INTERACTIVE QUESTIONS
# We ask everything upfront so the install can run unattended after this point.
# =============================================================================
section "Welcome to the Arch Installer"
echo "Answer the questions below. The install will begin after."
echo ""

# --- Profile ---
echo "Select a profile:"
echo "  1) Workstation  — full package set, assumes ethernet"
echo "  2) Laptop       — leaner package set, wifi setup included"
read -rp "Profile [1/2]: " PROFILE_INPUT
case "$PROFILE_INPUT" in
    1) PROFILE="workstation" ;;
    2) PROFILE="laptop" ;;
    *) error "Invalid profile selection." ;;
esac
success "Profile: $PROFILE"

# --- Wifi (laptop only) ---
# iwctl is the tool on the Arch live ISO for connecting to wifi.
# We connect here before anything else so pacstrap can download packages.
if [[ "$PROFILE" == "laptop" ]]; then
    section "Wifi Setup"
    read -rp "SSID (wifi network name): " WIFI_SSID
    read -rsp "Wifi password: " WIFI_PASSWORD
    echo ""
    info "Connecting to $WIFI_SSID..."
    # iwctl commands: power on the adapter, scan for networks, then connect.
    # We pipe commands into iwctl because it's an interactive program.
    iwctl --passphrase "$WIFI_PASSWORD" station wlan0 connect "$WIFI_SSID" \
        || error "Failed to connect to wifi. Check SSID and password."
    sleep 3
    # Verify we actually have internet before continuing
    ping -c 1 archlinux.org > /dev/null 2>&1 \
        || error "No internet after wifi connect. Check connection and retry."
    success "Connected to $WIFI_SSID"
fi

# --- Hostname ---
read -rp "Hostname (e.g. pearlybaker): " HOSTNAME
[[ -z "$HOSTNAME" ]] && error "Hostname cannot be empty."

# --- Username ---
read -rp "Username (e.g. clarkehines): " USERNAME
[[ -z "$USERNAME" ]] && error "Username cannot be empty."

# --- Disk ---
# We list available disks so you can see what's there before typing.
section "Disk Selection"
echo "Available disks:"
lsblk -dpno NAME,SIZE,MODEL | grep -v loop
echo ""
read -rp "Disk to install to (e.g. /dev/nvme0n1): " DISK
[[ ! -b "$DISK" ]] && error "Disk $DISK not found."

# --- Dual boot ---
read -rp "Dual boot with Windows? [y/N]: " DUAL_BOOT_INPUT
DUAL_BOOT=false
[[ "$DUAL_BOOT_INPUT" =~ ^[Yy]$ ]] && DUAL_BOOT=true

# Set EFI mount point based on dual boot.
# CRITICAL: For dual boot we mount EFI at /boot/efi so we don't overwrite
# the Windows bootloader. For single boot we mount at /boot directly.
if [[ "$DUAL_BOOT" == true ]]; then
    EFI_MOUNT="/boot/efi"
else
    EFI_MOUNT="/boot"
fi
success "EFI will be mounted at $EFI_MOUNT"

# --- CPU ---
echo ""
echo "Select CPU brand:"
echo "  1) Intel  — will install intel-ucode"
echo "  2) AMD    — will install amd-ucode"
read -rp "CPU [1/2]: " CPU_INPUT
case "$CPU_INPUT" in
    1) CPU="intel" ; UCODE="intel-ucode" ;;
    2) CPU="amd"   ; UCODE="amd-ucode"   ;;
    *) error "Invalid CPU selection." ;;
esac
success "CPU: $CPU ($UCODE)"

# --- Timezone ---
echo ""
echo "Select timezone:"
echo "  1) Europe/London    (UK)"
echo "  2) America/New_York (US East)"
echo "  3) America/Chicago  (US Central)"
echo "  4) America/Denver   (US Mountain)"
echo "  5) America/Los_Angeles (US West)"
echo "  6) Enter manually"
read -rp "Timezone [1-6]: " TZ_INPUT
case "$TZ_INPUT" in
    1) TIMEZONE="Europe/London" ;;
    2) TIMEZONE="America/New_York" ;;
    3) TIMEZONE="America/Chicago" ;;
    4) TIMEZONE="America/Denver" ;;
    5) TIMEZONE="America/Los_Angeles" ;;
    6) read -rp "Enter timezone (e.g. Europe/Berlin): " TIMEZONE ;;
    *) error "Invalid timezone selection." ;;
esac
success "Timezone: $TIMEZONE"

# --- LUKS ---
echo ""
read -rp "Enable LUKS encryption? [y/N]: " LUKS_INPUT
LUKS=false
if [[ "$LUKS_INPUT" =~ ^[Yy]$ ]]; then
    LUKS=true
    read -rsp "LUKS passphrase: " LUKS_PASS
    echo ""
    read -rsp "Confirm LUKS passphrase: " LUKS_PASS2
    echo ""
    [[ "$LUKS_PASS" != "$LUKS_PASS2" ]] && error "Passphrases do not match."
    success "LUKS encryption enabled"
fi

# --- Passwords ---
echo ""
read -rsp "Root password: " ROOT_PASSWORD
echo ""
read -rsp "Confirm root password: " ROOT_PASSWORD2
echo ""
[[ "$ROOT_PASSWORD" != "$ROOT_PASSWORD2" ]] && error "Root passwords do not match."

read -rsp "Password for $USERNAME: " USER_PASSWORD
echo ""
read -rsp "Confirm password for $USERNAME: " USER_PASSWORD2
echo ""
[[ "$USER_PASSWORD" != "$USER_PASSWORD2" ]] && error "User passwords do not match."

# --- Dotfiles ---
echo ""
read -rp "Dotfiles GitHub repo (default: Dequavis-Fitzgerald-III/dotfiles): " DOTFILES_REPO_INPUT
DOTFILES_REPO="${DOTFILES_REPO_INPUT:-Dequavis-Fitzgerald-III/dotfiles}"
DOTFILES_URL="https://github.com/$DOTFILES_REPO.git"

# --- Summary before we do anything destructive ---
section "Summary — Review Before Continuing"
echo "  Profile:    $PROFILE"
echo "  Hostname:   $HOSTNAME"
echo "  Username:   $USERNAME"
echo "  Disk:       $DISK"
echo "  Dual boot:  $DUAL_BOOT"
echo "  EFI mount:  $EFI_MOUNT"
echo "  CPU:        $CPU ($UCODE)"
echo "  Timezone:   $TIMEZONE"
echo "  LUKS:       $LUKS"
echo "  Dotfiles:   $DOTFILES_URL"
echo ""
warn "THIS WILL WIPE $DISK. There is no undo."
read -rp "Type YES to continue: " CONFIRM
[[ "$CONFIRM" != "YES" ]] && error "Aborted."

# =============================================================================
# SECTION 2 — PARTITIONING
# We use parted for scripted partitioning (no manual steps).
# Layout:
#   Partition 1 — EFI  (512MB, fat32)
#   Partition 2 — root (rest of disk, ext4) or LUKS container
# =============================================================================
section "Partitioning $DISK"

# Wipe any existing partition table and create a fresh GPT.
# GPT is required for UEFI systems. MBR is legacy, don't use it.
parted -s "$DISK" mklabel gpt

# EFI partition — 512MB is plenty for the bootloader and kernel files.
# We start at 1MiB to align to sector boundaries (avoids performance issues).
parted -s "$DISK" mkpart ESP fat32 1MiB 513MiB
parted -s "$DISK" set 1 esp on  # Mark as EFI System Partition

# Root partition — everything from 513MiB to end of disk.
parted -s "$DISK" mkpart primary ext4 513MiB 100%

success "Partitions created"

# Figure out partition names — nvme disks use p1/p2, sata disks use 1/2.
# e.g. /dev/nvme0n1 → /dev/nvme0n1p1 and /dev/nvme0n1p2
# e.g. /dev/sda     → /dev/sda1     and /dev/sda2
if [[ "$DISK" == *"nvme"* ]]; then
    EFI_PART="${DISK}p1"
    ROOT_PART="${DISK}p2"
else
    EFI_PART="${DISK}1"
    ROOT_PART="${DISK}2"
fi

# =============================================================================
# SECTION 3 — LUKS (if enabled)
# LUKS encrypts the root partition. We open it as "cryptroot" which creates
# a virtual device at /dev/mapper/cryptroot that we then format as ext4.
# =============================================================================
if [[ "$LUKS" == true ]]; then
    section "Setting up LUKS encryption"

    # Format the root partition as a LUKS container.
    # --type luks2 uses the modern LUKS2 format.
    # We echo the passphrase in so it doesn't prompt interactively.
    echo -n "$LUKS_PASS" | cryptsetup luksFormat --type luks2 "$ROOT_PART" -

    # Open (unlock) the LUKS container. This creates /dev/mapper/cryptroot.
    echo -n "$LUKS_PASS" | cryptsetup open "$ROOT_PART" cryptroot -

    # From here on, we install to the mapped device, not the raw partition.
    ROOT_DEVICE="/dev/mapper/cryptroot"
    success "LUKS container opened at $ROOT_DEVICE"
else
    ROOT_DEVICE="$ROOT_PART"
fi

# =============================================================================
# SECTION 4 — FORMAT & MOUNT
# =============================================================================
section "Formatting partitions"

# Format EFI as FAT32. -F 32 specifies FAT32 (not FAT16).
# dosfstools must be installed on the live ISO for this to work — it is by default.
mkfs.fat -F 32 "$EFI_PART"
success "EFI formatted as FAT32"

# Format root as ext4. -L sets the partition label for easy identification.
mkfs.ext4 -L root "$ROOT_DEVICE"
success "Root formatted as ext4"

section "Mounting partitions"

# Mount root first, then create mount points inside it.
mount "$ROOT_DEVICE" /mnt
success "Root mounted at /mnt"

# Create and mount EFI. The mount point depends on dual boot choice.
mkdir -p "/mnt$EFI_MOUNT"
mount "$EFI_PART" "/mnt$EFI_MOUNT"
success "EFI mounted at /mnt$EFI_MOUNT"

# =============================================================================
# SECTION 5 — PACSTRAP
# pacstrap installs packages into /mnt (the new system), not the live ISO.
# Everything listed here is available in base install without AUR.
# =============================================================================
section "Installing base system (pacstrap)"
info "This will take a while depending on your connection..."

# Build the package list. We start with packages common to all profiles.
PACKAGES=(
    # Base system
    base linux linux-firmware

    # CPU microcode — corrects CPU bugs at boot. Always install the right one.
    "$UCODE"

    # Filesystem tools — dosfstools is required to manage the FAT32 EFI partition.
    # Without it, fstab generation for vfat will fail.
    dosfstools

    # Network
    networkmanager

    # Essential tools
    sudo nano git base-devel openssh

    # Audio — pipewire is the modern audio server replacing pulseaudio.
    # pipewire-pulse makes it compatible with pulseaudio apps.
    # wireplumber is the session manager that connects apps to audio devices.
    # sof-firmware provides firmware for Intel Sound Open Firmware audio (common in laptops).
    alsa-utils sof-firmware pipewire pipewire-pulse wireplumber

    # Desktop — Hyprland is a Wayland compositor (the thing that draws windows).
    hyprland hyprpaper dunst waybar kitty
    rofi-wayland xdg-desktop-portal-hyprland
    polkit-gnome sddm

    # System
    ufw flatpak

    # Fonts
    ttf-input-nerd
)

# Workstation-only packages
if [[ "$PROFILE" == "workstation" ]]; then
    PACKAGES+=(ollama)
fi

# Laptop-only packages
if [[ "$PROFILE" == "laptop" ]]; then
    # tlp — battery management daemon, extends laptop battery life
    # brightnessctl — controls screen backlight brightness
    # bluez — the Bluetooth protocol stack
    # bluez-utils — command line tools for Bluetooth (bluetoothctl etc.)
    PACKAGES+=(tlp brightnessctl bluez bluez-utils)
fi

# Run pacstrap with our package list.
# The -- separates the mount point from the package list.
pacstrap /mnt "${PACKAGES[@]}"
success "Base system installed"

# =============================================================================
# SECTION 6 — FSTAB
# fstab tells the system what to mount at boot and where.
# genfstab generates this automatically based on what's currently mounted.
# =============================================================================
section "Generating fstab"

# -U uses UUIDs instead of device names (e.g. /dev/sda1).
# UUIDs are stable — device names can change if you add/remove disks.
genfstab -U /mnt >> /mnt/etc/fstab

# Add nofail to the EFI partition entry.
# nofail means if the EFI partition fails to mount, the system still boots.
# This is important for dual boot — if Windows does something to the EFI
# partition, Arch can still start.
# We use sed to find the EFI partition line and add nofail to its options.
sed -i "s|$EFI_PART|& |" /mnt/etc/fstab  # no-op, just ensures spacing
# Find the line with the EFI mount and append nofail to options field
sed -i "\|$EFI_MOUNT|s/defaults/defaults,nofail/" /mnt/etc/fstab

success "fstab generated"
info "fstab contents:"
cat /mnt/etc/fstab

# =============================================================================
# SECTION 7 — CHROOT CONFIGURATION
# arch-chroot changes root into the new system so we can configure it
# as if we're running inside it. Everything from here runs inside /mnt.
# =============================================================================
section "Entering chroot to configure system"

# We pass all our variables into the chroot via a heredoc.
# The variables are expanded before the heredoc runs (note: no quotes around EOF).
arch-chroot /mnt /bin/bash <<EOF

set -e

# --- Timezone ---
# Create a symlink from the timezone file to /etc/localtime.
# This is how Arch (and most Linux distros) set the timezone.
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime

# Sync the hardware clock to the system clock using UTC.
# We always keep the hardware clock on UTC — timezone is just a display setting.
hwclock --systohc
echo "Timezone set to $TIMEZONE"

# --- Locale ---
# Uncomment en_GB.UTF-8 in locale.gen, then generate the locale.
# en_GB gives us British English — correct date formats, spellings etc.
sed -i 's/^#en_GB.UTF-8/en_GB.UTF-8/' /etc/locale.gen
locale-gen

# Write the locale config file. No trailing whitespace — it causes issues.
echo 'LANG=en_GB.UTF-8' > /etc/locale.conf
echo "Locale set to en_GB.UTF-8"

# --- Hostname ---
echo "$HOSTNAME" > /etc/hostname

# /etc/hosts maps hostnames to IP addresses locally.
# 127.0.1.1 should map to your hostname — required for some apps.
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
HOSTS
echo "Hostname set to $HOSTNAME"

# --- Passwords ---
# Set root password. We echo it in to avoid interactive prompt.
echo "root:$ROOT_PASSWORD" | chpasswd
echo "Root password set"

# --- User ---
# Create the user with:
#   -m  = create home directory
#   -G  = add to groups (wheel = sudo access, audio/video = device access)
#   -s  = set default shell
useradd -m -G wheel,audio,video,storage -s /bin/bash "$USERNAME"
echo "$USERNAME:$USER_PASSWORD" | chpasswd
echo "User $USERNAME created"

# --- Sudo ---
# Uncomment the %wheel line so members of the wheel group can use sudo.
# NOPASSWD is NOT set — you'll be prompted for your password.
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# --- mkinitcpio (LUKS) ---
# If LUKS is enabled we need to add the 'encrypt' hook to mkinitcpio.
# Hooks run during boot to prepare the system — encrypt unlocks the LUKS
# partition before the root filesystem is mounted.
if [[ "$LUKS" == true ]]; then
    # Add 'encrypt' hook before 'filesystems' in the HOOKS line
    sed -i 's/HOOKS=(base udev autodetect/HOOKS=(base udev autodetect keyboard keymap/' /etc/mkinitcpio.conf
    sed -i 's/block filesystems/block encrypt filesystems/' /etc/mkinitcpio.conf
    mkinitcpio -P  # Regenerate all initramfs images
    echo "mkinitcpio regenerated with encrypt hook"
fi

# --- Bootloader: systemd-boot ---
# systemd-boot is a simple UEFI bootloader included in systemd.
# We prefer it over GRUB — it's simpler and perfectly capable for our needs.
bootctl install --path="$EFI_MOUNT"

# --- Boot loader entries ---
# Get the UUID of the root partition (or LUKS partition if encrypted).
# The UUID is used in the boot entry so systemd-boot knows what to boot.
if [[ "$LUKS" == true ]]; then
    # For LUKS, we need the UUID of the raw partition (before decryption)
    # so the bootloader knows which device to decrypt at boot.
    ROOT_UUID=\$(blkid -s UUID -o value "$ROOT_PART")
    KERNEL_OPTIONS="rd.luks.name=\$ROOT_UUID=cryptroot root=/dev/mapper/cryptroot rw quiet"
else
    ROOT_UUID=\$(blkid -s UUID -o value "$ROOT_DEVICE")
    KERNEL_OPTIONS="root=UUID=\$ROOT_UUID rw quiet"
fi

# Write the boot entry for Arch Linux.
# Each line tells systemd-boot something about how to boot.
cat > "$EFI_MOUNT/loader/entries/arch.conf" <<BOOTENTRY
title   Arch Linux
linux   /vmlinuz-linux
initrd  /$UCODE.img
initrd  /initramfs-linux.img
options \$KERNEL_OPTIONS
BOOTENTRY

# Write the loader config — sets default entry and timeout.
cat > "$EFI_MOUNT/loader/loader.conf" <<LOADERCONF
default arch.conf
timeout 5
editor  no
LOADERCONF

echo "systemd-boot configured"

# --- Copy kernel to EFI (dual boot) ---
# For dual boot, the kernel files live in /boot but the EFI partition is
# at /boot/efi. systemd-boot needs the kernel in the EFI partition.
# We copy them manually here and set up a pacman hook to keep them in sync.
if [[ "$DUAL_BOOT" == true ]]; then
    cp /boot/vmlinuz-linux "$EFI_MOUNT/"
    cp /boot/$UCODE.img "$EFI_MOUNT/"
    cp /boot/initramfs-linux.img "$EFI_MOUNT/"
    echo "Kernel files copied to EFI partition"

    # Pacman hook — runs after every linux package update to re-copy the kernel.
    # Without this, kernel updates won't take effect on the next boot because
    # the old kernel file is still sitting in the EFI partition.
    mkdir -p /etc/pacman.d/hooks
    cat > /etc/pacman.d/hooks/copy-kernel.hook <<HOOK
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = linux

[Action]
Depends = rsync
When = PostTransaction
Exec = /bin/sh -c 'rsync /boot/vmlinuz-linux /boot/$UCODE.img /boot/initramfs-linux.img $EFI_MOUNT/ 2>/dev/null || true'
HOOK
    echo "Pacman hook installed for kernel updates"
fi

# --- Services ---
# Enable services so they start automatically on boot.
systemctl enable NetworkManager   # Network management
systemctl enable sddm             # Display manager (login screen)
systemctl enable ufw              # Firewall

# Profile-specific services
if [[ "$PROFILE" == "laptop" ]]; then
    systemctl enable tlp          # Battery management
    systemctl enable bluetooth    # Bluetooth
fi

echo "Services enabled"
echo ""
echo "Chroot configuration complete."
EOF

success "Chroot configuration done"

# =============================================================================
# SECTION 8 — POST-INSTALL SCRIPT SETUP
# Copy post-install.sh to the new user's home directory so it's ready
# to run after first boot.
# =============================================================================
section "Setting up post-install script"

# Copy post-install.sh into the new system if it exists next to this script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/post-install.sh" ]]; then
    cp "$SCRIPT_DIR/post-install.sh" /mnt/home/"$USERNAME"/
    chmod +x /mnt/home/"$USERNAME"/post-install.sh
    # Write the variables post-install.sh will need into a config file
    # so it knows the username, profile, dotfiles URL etc.
    cat > /mnt/home/"$USERNAME"/.install-config <<INSTALLCONF
USERNAME=$USERNAME
PROFILE=$PROFILE
DOTFILES_URL=$DOTFILES_URL
TIMEZONE=$TIMEZONE
INSTALLCONF
    success "post-install.sh copied to /home/$USERNAME/"
    info "After first boot, run: bash ~/post-install.sh"
else
    warn "post-install.sh not found next to install.sh — copy it manually."
fi

# =============================================================================
# DONE
# =============================================================================
section "Installation Complete"
success "Arch Linux has been installed to $DISK"
echo ""
echo "Next steps:"
echo "  1. Run: umount -R /mnt"
if [[ "$LUKS" == true ]]; then
    echo "  2. Run: cryptsetup close cryptroot"
fi
echo "  3. Remove the USB drive"
echo "  4. Reboot: reboot"
echo "  5. Log in as $USERNAME"
echo "  6. Run: bash ~/post-install.sh"
echo ""
