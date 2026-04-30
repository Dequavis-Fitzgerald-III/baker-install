#!/bin/bash
# =============================================================================
# Baker Configure Script
# Applies idempotent system configuration from ~/.baker-config.
# Called by install.sh (inside the chroot) and upgrade.sh (on a live system).
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

# Source .baker-config if vars aren't already in the environment.
# When called from install.sh chroot, vars are exported before this runs.
# When called from upgrade.sh, the config path is passed as $1.
[[ -z "$PROFILE" ]] && source "${1:-$HOME/.baker-config}"

# =============================================================================
# TIMEZONE
# =============================================================================
section "Timezone"
ln -sf /usr/share/zoneinfo/"$TIMEZONE" /etc/localtime
hwclock --systohc
success "Timezone: $TIMEZONE"

# =============================================================================
# LOCALE
# Uncomments the locale in locale.gen if not already active, then regenerates.
# =============================================================================
section "Locale"
if ! locale -a 2>/dev/null | grep -qF "${LOCALE}"; then
    sed -i "s|^#${LOCALE}|${LOCALE}|" /etc/locale.gen
    locale-gen
    success "Locale generated: $LOCALE"
else
    success "Locale already active, skipping generation"
fi
echo "LANG=$LOCALE" > /etc/locale.conf

# =============================================================================
# CONSOLE KEYMAP
# vconsole.conf must exist before mkinitcpio runs so the keymap hook
# has something to bake into the initramfs.
# =============================================================================
section "Console keymap"
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf
success "Keymap: $KEYMAP"

# =============================================================================
# HOSTNAME
# hostnamectl applies the change immediately on a live system.
# It fails silently in the chroot (systemd not running) — the file write handles that case.
# =============================================================================
section "Hostname"
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
HOSTS
hostnamectl set-hostname "$HOSTNAME" 2>/dev/null || true
success "Hostname: $HOSTNAME"

# =============================================================================
# SUDO
# Uncomments the wheel group line in /etc/sudoers.
# sed is idempotent — if the line is already uncommented it matches and rewrites identically.
# =============================================================================
section "Sudo"
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
success "sudo configured for wheel group"

# =============================================================================
# HYPRLAND-WELCOME
# Pulled in as a dependency of hyprland — we never want it.
# =============================================================================
section "Removing hyprland-welcome"
pacman -Rns --noconfirm hyprland-welcome 2>/dev/null || true
success "hyprland-welcome removed"

# =============================================================================
# HDD MOUNT POINT
# The fstab entry is written by install.sh, but the directory must exist
# before the first boot so the mount succeeds.
# =============================================================================
if [[ "$HDD" == true ]]; then
    section "HDD mount point"
    mkdir -p "$HDD_MOUNT"
    success "Mount point: $HDD_MOUNT"
fi

# =============================================================================
# MKINITCPIO HOOKS
# We replace the entire HOOKS line — patching individual hooks is fragile.
# Only regenerates the initramfs if the line actually changed, since mkinitcpio -P
# is slow and we don't want it running on every baker-update unnecessarily.
#
# Hook order:
#   base udev autodetect microcode modconf [kms] keyboard keymap block [encrypt] filesystems fsck
#
# kms is excluded for Nvidia — it conflicts with the proprietary driver and causes
# a black screen on boot. encrypt is only included when LUKS is enabled.
# =============================================================================
section "mkinitcpio"

HOOKS="base udev autodetect microcode modconf"
[[ "$GPU" != "nvidia" ]] && HOOKS="$HOOKS kms"
HOOKS="$HOOKS keyboard keymap block"
[[ "$LUKS" == true ]] && HOOKS="$HOOKS encrypt"
HOOKS="$HOOKS filesystems fsck"
DESIRED_HOOKS="HOOKS=($HOOKS)"

CURRENT_HOOKS=$(grep "^HOOKS=" /etc/mkinitcpio.conf)
if [[ "$CURRENT_HOOKS" != "$DESIRED_HOOKS" ]]; then
    sed -i "s|^HOOKS=.*|$DESIRED_HOOKS|" /etc/mkinitcpio.conf
    mkinitcpio -P
    success "HOOKS updated and initramfs regenerated"
else
    success "HOOKS already correct, skipping rebuild"
fi

# =============================================================================
# GRUB CONFIGURATION
# Builds the kernel cmdline from LUKS_UUID and GPU, sets timeout to indefinite,
# enables os-prober for dual boot. Only runs grub-mkconfig if something changed.
# =============================================================================
section "GRUB"

GRUB_CHANGED=false

# Build desired kernel cmdline from config
GRUB_CMDLINE=""
if [[ "$LUKS" == true && -n "$LUKS_UUID" ]]; then
    GRUB_CMDLINE="cryptdevice=UUID=${LUKS_UUID}:cryptroot root=/dev/mapper/cryptroot"
fi
if [[ "$GPU" == "nvidia" ]]; then
    GRUB_CMDLINE="${GRUB_CMDLINE:+$GRUB_CMDLINE }nvidia_drm.modeset=1"
fi

CURRENT_CMDLINE=$(grep "^GRUB_CMDLINE_LINUX=" /etc/default/grub)
DESIRED_CMDLINE="GRUB_CMDLINE_LINUX=\"$GRUB_CMDLINE\""
if [[ "$CURRENT_CMDLINE" != "$DESIRED_CMDLINE" ]]; then
    sed -i "s|^GRUB_CMDLINE_LINUX=.*|$DESIRED_CMDLINE|" /etc/default/grub
    info "GRUB cmdline updated"
    GRUB_CHANGED=true
fi

CURRENT_TIMEOUT=$(grep "^GRUB_TIMEOUT=" /etc/default/grub)
if [[ "$CURRENT_TIMEOUT" != "GRUB_TIMEOUT=-1" ]]; then
    sed -i "s|^GRUB_TIMEOUT=.*|GRUB_TIMEOUT=-1|" /etc/default/grub
    info "GRUB timeout set to indefinite"
    GRUB_CHANGED=true
fi

if [[ "$DUAL_BOOT" == true ]]; then
    if ! grep -q "^GRUB_DISABLE_OS_PROBER=false" /etc/default/grub; then
        if grep -q "GRUB_DISABLE_OS_PROBER" /etc/default/grub; then
            sed -i 's/.*GRUB_DISABLE_OS_PROBER.*/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub
        else
            echo "GRUB_DISABLE_OS_PROBER=false" >> /etc/default/grub
        fi
        info "os-prober enabled for dual boot"
        GRUB_CHANGED=true
    fi
fi

if [[ "$GRUB_CHANGED" == true ]]; then
    grub-mkconfig -o /boot/grub/grub.cfg
    success "GRUB config updated and regenerated"
else
    success "GRUB config already correct, skipping regeneration"
fi

# =============================================================================
# SSHD HARDENING
# Drop-in file so we don't clobber the stock sshd_config.
# Key-only auth enforced from first boot — password auth never exposed.
# =============================================================================
section "sshd hardening"
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-baker.conf <<SSHDCONF
PasswordAuthentication no
PubkeyAuthentication yes
SSHDCONF
success "sshd hardened (key-only auth)"

section "Configuration complete"
