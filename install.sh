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
# Order: profile → hostname → username → cpu → gpu → timezone → wifi (laptop only)
#        → disk → dual boot → hdd (workstation only) → luks → passwords → dotfiles
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

# --- Hostname ---
# Defaults make re-runs faster on known machines.
echo ""
read -rp "Hostname [default: nomadbaker for laptop, pearlybaker for workstation]: " HOSTNAME
if [[ -z "$HOSTNAME" ]]; then
    [[ "$PROFILE" == "laptop" ]] && HOSTNAME="nomadbaker" || HOSTNAME="pearlybaker"
fi
success "Hostname: $HOSTNAME"

# --- Username ---
read -rp "Username [default: clarkehines]: " USERNAME
USERNAME="${USERNAME:-clarkehines}"
success "Username: $USERNAME"

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

# --- GPU ---
echo ""
echo "Select GPU brand:"
echo "  1) Nvidia  — will install nvidia, nvidia-utils, nvidia-settings"
echo "  2) AMD     — will install mesa, vulkan-radeon, libva-mesa-driver"
echo "  3) Intel   — will install mesa, vulkan-intel, intel-media-driver"
echo "  4) None    — skip GPU drivers"
read -rp "GPU [1-4]: " GPU_INPUT
case "$GPU_INPUT" in
    1) GPU="nvidia" ;;
    2) GPU="amd"    ;;
    3) GPU="intel"  ;;
    4) GPU="none"   ;;
    *) error "Invalid GPU selection." ;;
esac
success "GPU: $GPU"

# --- Timezone ---
echo ""
echo "Select timezone:"
echo "  1) Europe/London    (UK)"
echo "  2) America/New_York (US East)"
echo "  3) Enter manually"
read -rp "Timezone [1-3]: " TZ_INPUT
case "$TZ_INPUT" in
    1) TIMEZONE="Europe/London" ;;
    2) TIMEZONE="America/New_York" ;;
    3) read -rp "Enter timezone (e.g. Europe/Berlin): " TIMEZONE ;;
    *) error "Invalid timezone selection." ;;
esac
success "Timezone: $TIMEZONE"

# --- Wifi (laptop only) ---
# We only ask for wifi credentials if we're not already online.
# This avoids failing when already connected (e.g. you ran the script to
# download it) or when using a USB ethernet dongle.
WIFI_SSID=""
WIFI_PASSWORD=""
if [[ "$PROFILE" == "laptop" ]]; then
    section "Network Check"
    if ping -c 1 -W 3 archlinux.org > /dev/null 2>&1; then
        success "Already connected to the internet, skipping wifi setup"
    else
        info "No internet detected. Setting up wifi..."
        read -rp "SSID (wifi network name): " WIFI_SSID
        read -rsp "Wifi password: " WIFI_PASSWORD
        echo ""
        info "Connecting to $WIFI_SSID..."
        # iwctl is the wifi tool on the Arch live ISO.
        # We pipe commands into it because it's an interactive program.
        iwctl --passphrase "$WIFI_PASSWORD" station wlan0 connect "$WIFI_SSID" \
            || error "Failed to connect to wifi. Check SSID and password."
        sleep 3
        ping -c 1 -W 3 archlinux.org > /dev/null 2>&1 \
            || error "No internet after wifi connect. Check connection and retry."
        success "Connected to $WIFI_SSID"
    fi
fi

# --- Primary Disk ---
# We list available disks so you can see what's there before typing.
section "Disk Selection"
echo "Available disks:"
lsblk -dpno NAME,SIZE,MODEL | grep -v loop
echo ""
read -rp "Disk to install to (e.g. /dev/nvme0n1): " DISK
[[ ! -b "$DISK" ]] && error "Disk $DISK not found."
success "System will be installed on $DISK"

# --- Dual boot ---
read -rp "Dual boot with Windows? [y/N]: " DUAL_BOOT_INPUT
DUAL_BOOT=false
[[ "$DUAL_BOOT_INPUT" =~ ^[Yy]$ ]] && DUAL_BOOT=true

# DUAL_FRESH: only relevant when DUAL_BOOT=true.
#   true  — wipe the whole disk; both Windows and Linux start from scratch.
#   false — Windows already exists; only the Linux partition is wiped and recreated.
DUAL_FRESH=false
DUAL_EFI_PART=""
OLD_LINUX_PART=""

if [[ "$DUAL_BOOT" == true ]]; then
    echo ""
    echo "  fresh — wipe the whole disk (Windows gone, reinstall later)"
    echo "  keep  — Windows already installed; preserve it"
    read -rp "Fresh install or keep existing Windows? [fresh/keep]: " DUAL_MODE
    case "$DUAL_MODE" in
        fresh|FRESH) DUAL_FRESH=true ;;
        keep|KEEP)   DUAL_FRESH=false ;;
        *) error "Enter 'fresh' or 'keep'." ;;
    esac

    if [[ "$DUAL_FRESH" == false ]]; then
        echo ""
        echo "Current layout of $DISK:"
        parted "$DISK" print
        echo ""
        read -rp "Windows EFI partition to reuse (e.g. ${DISK}p2): " DUAL_EFI_PART
        [[ ! -b "$DUAL_EFI_PART" ]] && error "Partition $DUAL_EFI_PART not found."
        success "Will reuse existing EFI: $DUAL_EFI_PART"
        read -rp "Existing Linux root partition to wipe (leave blank if none): " OLD_LINUX_PART
        if [[ -n "$OLD_LINUX_PART" ]]; then
            [[ ! -b "$OLD_LINUX_PART" ]] && error "Partition $OLD_LINUX_PART not found."
            warn "Will delete $OLD_LINUX_PART and recreate it for Arch"
        fi
    fi
fi

# Set EFI mount point based on dual boot.
# CRITICAL: For dual boot we mount EFI at /boot/efi so we don't overwrite
# the Windows bootloader. For single boot we mount at /boot directly.
if [[ "$DUAL_BOOT" == true ]]; then
    EFI_MOUNT="/boot/efi"
else
    EFI_MOUNT="/boot"
fi
success "EFI will be mounted at $EFI_MOUNT"

# --- Secondary HDD (workstation only) ---
# On workstation we support an optional secondary internal drive.
# We detect the partition, filesystem, and UUID dynamically — no hardcoding.
HDD=false
HDD_PART=""
HDD_UUID=""
HDD_FSTYPE=""
HDD_MOUNT=""

if [[ "$PROFILE" == "workstation" ]]; then
    echo ""
    read -rp "Mount a secondary internal HDD? [y/N]: " HDD_INPUT
    if [[ "$HDD_INPUT" =~ ^[Yy]$ ]]; then
        HDD=true

        echo ""
        echo "Available disks (excluding the primary install disk):"
        lsblk -dpno NAME,SIZE,MODEL | grep -v loop | grep -v "^$DISK "
        echo ""
        read -rp "Secondary drive (e.g. /dev/sda): " HDD_DISK
        [[ ! -b "$HDD_DISK" ]] && error "Disk $HDD_DISK not found."

        # Detect the single partition on the drive.
        HDD_PART=$(lsblk -lnpo NAME "$HDD_DISK" | grep -v "^$HDD_DISK$" | head -n1)
        [[ -z "$HDD_PART" ]] && error "No partition found on $HDD_DISK. Is the drive partitioned?"
        success "Found partition: $HDD_PART"

        # Detect filesystem type and UUID dynamically.
        HDD_FSTYPE=$(blkid -s TYPE -o value "$HDD_PART")
        HDD_UUID=$(blkid -s UUID -o value "$HDD_PART")
        [[ -z "$HDD_FSTYPE" ]] && error "Could not detect filesystem on $HDD_PART."
        [[ -z "$HDD_UUID" ]]   && error "Could not detect UUID on $HDD_PART."
        success "Filesystem: $HDD_FSTYPE | UUID: $HDD_UUID"

        read -rp "Mount point [default: /mnt/hdd]: " HDD_MOUNT_INPUT
        HDD_MOUNT="${HDD_MOUNT_INPUT:-/mnt/hdd}"
        success "HDD will be mounted at $HDD_MOUNT"
    fi
fi

# --- LUKS ---
echo ""
read -rp "Enable LUKS encryption? [y/N]: " LUKS_INPUT
LUKS=false
ROOT_PASSWORD=""
USER_PASSWORD=""
if [[ "$LUKS_INPUT" =~ ^[Yy]$ ]]; then
    LUKS=true
    read -rsp "LUKS passphrase: " LUKS_PASS
    echo ""
    read -rsp "Confirm LUKS passphrase: " LUKS_PASS2
    echo ""
    [[ "$LUKS_PASS" != "$LUKS_PASS2" ]] && error "Passphrases do not match."
    success "LUKS passphrase confirmed"

    read -rp "Use LUKS passphrase for all system passwords? [y/N]: " LUKS_REUSE_ALL
    if [[ "$LUKS_REUSE_ALL" =~ ^[Yy]$ ]]; then
        ROOT_PASSWORD="$LUKS_PASS"
        USER_PASSWORD="$LUKS_PASS"
        success "Using LUKS passphrase for root and user"
    else
        read -rp "Use LUKS passphrase as root password? [y/N]: " LUKS_REUSE_ROOT
        [[ "$LUKS_REUSE_ROOT" =~ ^[Yy]$ ]] && ROOT_PASSWORD="$LUKS_PASS" && success "Using LUKS passphrase for root"

        read -rp "Use LUKS passphrase as user password? [y/N]: " LUKS_REUSE_USER
        [[ "$LUKS_REUSE_USER" =~ ^[Yy]$ ]] && USER_PASSWORD="$LUKS_PASS" && success "Using LUKS passphrase for user"
    fi
fi

# --- Passwords ---
# Only prompt for passwords that weren't covered by LUKS reuse above.
if [[ -z "$ROOT_PASSWORD" && -z "$USER_PASSWORD" ]]; then
    echo ""
    read -rp "Set root and user password the same? [y/N]: " EQUAL_PASSWORDS
    if [[ "$EQUAL_PASSWORDS" =~ ^[Yy]$ ]]; then
        read -rsp "System password: " SYSTEM_PASSWORD
        echo ""
        read -rsp "Confirm system password: " SYSTEM_PASSWORD2
        echo ""
        [[ "$SYSTEM_PASSWORD" != "$SYSTEM_PASSWORD2" ]] && error "Passwords do not match."
        success "System password confirmed"
        ROOT_PASSWORD="$SYSTEM_PASSWORD"
        USER_PASSWORD="$SYSTEM_PASSWORD"
    else
        read -rsp "Root password: " ROOT_PASSWORD
        echo ""
        read -rsp "Confirm root password: " ROOT_PASSWORD2
        echo ""
        [[ "$ROOT_PASSWORD" != "$ROOT_PASSWORD2" ]] && error "Root passwords do not match."
        success "Root password confirmed"

        read -rsp "Password for $USERNAME: " USER_PASSWORD
        echo ""
        read -rsp "Confirm password for $USERNAME: " USER_PASSWORD2
        echo ""
        [[ "$USER_PASSWORD" != "$USER_PASSWORD2" ]] && error "User passwords do not match."
        success "$USERNAME password confirmed"
    fi
elif [[ -z "$ROOT_PASSWORD" ]]; then
    echo ""
    read -rsp "Root password: " ROOT_PASSWORD
    echo ""
    read -rsp "Confirm root password: " ROOT_PASSWORD2
    echo ""
    [[ "$ROOT_PASSWORD" != "$ROOT_PASSWORD2" ]] && error "Root passwords do not match."
    success "Root password confirmed"
elif [[ -z "$USER_PASSWORD" ]]; then
    echo ""
    read -rsp "Password for $USERNAME: " USER_PASSWORD
    echo ""
    read -rsp "Confirm password for $USERNAME: " USER_PASSWORD2
    echo ""
    [[ "$USER_PASSWORD" != "$USER_PASSWORD2" ]] && error "User passwords do not match."
    success "$USERNAME password confirmed"
fi

# --- Dotfiles ---
echo ""
read -rp "Dotfiles GitHub repo (default: Dequavis-Fitzgerald-III/dotfiles): " DOTFILES_REPO_INPUT
DOTFILES_REPO="${DOTFILES_REPO_INPUT:-Dequavis-Fitzgerald-III/dotfiles}"
DOTFILES_URL="https://github.com/$DOTFILES_REPO.git"
success "Dotfiles repo: $DOTFILES_URL"

# --- Summary before we do anything destructive ---
section "Summary — Review Before Continuing"
echo "  Profile:    $PROFILE"
echo "  Hostname:   $HOSTNAME"
echo "  Username:   $USERNAME"
echo "  CPU:        $CPU ($UCODE)"
echo "  GPU:        $GPU"
echo "  Timezone:   $TIMEZONE"
echo "  Disk:       $DISK"
echo "  Dual boot:  $DUAL_BOOT"
if [[ "$DUAL_BOOT" == true ]]; then
    if [[ "$DUAL_FRESH" == true ]]; then
        echo "  Dual mode:  fresh (full wipe)"
    else
        echo "  Dual mode:  keep Windows"
        echo "  Windows EFI: $DUAL_EFI_PART"
        [[ -n "$OLD_LINUX_PART" ]] && echo "  Linux part to wipe: $OLD_LINUX_PART"
    fi
fi
echo "  EFI mount:  $EFI_MOUNT"
if [[ "$HDD" == true ]]; then
    echo "  HDD:        $HDD_PART ($HDD_FSTYPE) → $HDD_MOUNT"
fi
echo "  LUKS:       $LUKS"
echo "  Dotfiles:   $DOTFILES_URL"
echo ""
warn "THIS WILL WIPE $DISK. There is no undo."
read -rp "Type YES to continue: " CONFIRM
[[ "$CONFIRM" != "YES" ]] && error "Aborted."
success "Confirmed, beginning install."

# =============================================================================
# SECTION 2 — PARTITIONING
# We use parted for scripted partitioning (no manual steps).
# Layout:
#   Partition 1 — EFI  (512MB, fat32)
#   Partition 2 — root (rest of disk, ext4 or LUKS container)
# =============================================================================
section "Partitioning $DISK"

if [[ "$DUAL_BOOT" == true && "$DUAL_FRESH" == false ]]; then
    # Keep Windows: never touch the partition table or Windows partitions.
    # Delete the old Linux root if given, then create a new one in the free space.

    if [[ -n "$OLD_LINUX_PART" ]]; then
        PART_NUM=$(echo "$OLD_LINUX_PART" | grep -o '[0-9]*$')
        parted -s "$DISK" rm "$PART_NUM"
        success "Deleted old Linux partition $OLD_LINUX_PART"
        partprobe "$DISK"
    fi

    # Find the start of the largest free space block on the disk.
    FREE_START=$(parted -s "$DISK" unit MiB print free \
        | awk '/Free Space/ {
            start=$1; gsub(/MiB/,"",start)
            size=$3;  gsub(/MiB/,"",size)
            if (size+0 > max+0) { max=size+0; best=start }
          } END { print best }')
    [[ -z "$FREE_START" ]] && error "No free space found on $DISK."
    info "Creating root partition from ${FREE_START}MiB to end of disk"

    parted -s "$DISK" mkpart primary ext4 "${FREE_START}MiB" 100%
    partprobe "$DISK"
    success "Root partition created"

    ROOT_PART_NUM=$(parted -s "$DISK" print | awk '/^ [0-9]/ {last=$1} END {print last}')
    EFI_PART="$DUAL_EFI_PART"
    if [[ "$DISK" == *"nvme"* ]] || [[ "$DISK" == *"mmcblk"* ]]; then
        ROOT_PART="${DISK}p${ROOT_PART_NUM}"
    else
        ROOT_PART="${DISK}${ROOT_PART_NUM}"
    fi

else
    # Fresh install (single boot or dual boot clean slate): wipe and start over.
    parted -s "$DISK" mklabel gpt
    success "GPT created"

    parted -s "$DISK" mkpart ESP fat32 1MiB 513MiB
    parted -s "$DISK" set 1 esp on
    success "EFI partition created"

    parted -s "$DISK" mkpart primary ext4 513MiB 100%
    success "Root partition created"

    if [[ "$DISK" == *"nvme"* ]] || [[ "$DISK" == *"mmcblk"* ]]; then
        EFI_PART="${DISK}p1"
        ROOT_PART="${DISK}p2"
    else
        EFI_PART="${DISK}1"
        ROOT_PART="${DISK}2"
    fi
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
    success "LUKS container formatted on $ROOT_PART"

    # Open (unlock) the LUKS container. This creates /dev/mapper/cryptroot.
    echo -n "$LUKS_PASS" | cryptsetup open "$ROOT_PART" cryptroot -

    # From here on, we install to the mapped device, not the raw partition.
    ROOT_DEVICE="/dev/mapper/cryptroot"
    success "LUKS container opened at $ROOT_DEVICE"

    LUKS_UUID=$(blkid -s UUID -o value "$ROOT_PART")
    info "LUKS UUID: $LUKS_UUID"
else
    ROOT_DEVICE="$ROOT_PART"
fi

# =============================================================================
# SECTION 4 — FORMAT & MOUNT
# =============================================================================
section "Formatting partitions"

# Format EFI as FAT32 only on a fresh install.
# When keeping Windows the EFI already exists — formatting it wipes the Windows bootloader.
if [[ "$DUAL_BOOT" == true && "$DUAL_FRESH" == false ]]; then
    info "Dual boot (keep Windows): skipping EFI format — reusing existing ESP"
else
    mkfs.fat -F 32 "$EFI_PART"
    success "EFI formatted as FAT32"
fi

# Format root as ext4. -L sets a label for easy identification.
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
# Everything listed here is available in the official repos (no AUR needed).
# =============================================================================
section "Installing base system (pacstrap)"
info "This will take a while depending on your connection..."

# Fetch package lists from the baker manifests.
# Manifests hold the "ongoing" packages — tools and apps for a running system.
# Bootstrap packages (kernel, bootloader, fs tools, hardware drivers) are added
# directly here because they are install-time only or hardware-specific.
REPO_RAW="https://raw.githubusercontent.com/Dequavis-Fitzgerald-III/baker/main"

info "Fetching package manifests from baker repo..."

# Extracts a named [section] block from manifest content piped via stdin.
parse_section() {
    awk "/^\[$1\]/{found=1; next} /^\[/{found=0} found && !/^#/ && NF"
}

PACKAGES=()
while IFS= read -r pkg; do
    PACKAGES+=("$pkg")
done < <(
    curl -fsSL "$REPO_RAW/packages/base.txt"     | parse_section pacman
    curl -fsSL "$REPO_RAW/packages/$PROFILE.txt" | parse_section pacman
)

# Bootstrap packages — install-time only, not in manifests
PACKAGES+=(base linux linux-firmware "$UCODE" dosfstools grub efibootmgr os-prober)

# GPU drivers — hardware-specific, not in manifests
if [[ "$GPU" == "nvidia" ]]; then
    PACKAGES+=(nvidia-dkms nvidia-utils nvidia-settings)
elif [[ "$GPU" == "amd" ]]; then
    PACKAGES+=(mesa vulkan-radeon libva-mesa-driver)
elif [[ "$GPU" == "intel" ]]; then
    PACKAGES+=(mesa vulkan-intel intel-media-driver)
fi

# Fix keyring before pacstrap — old ISO keyrings cause signature verification
# errors when installing packages from current repos.
pacman-key --init
pacman-key --populate archlinux
pacman -Sy archlinux-keyring

# Refresh package databases on the live ISO before installing.
# Without this, pacstrap uses stale DB files from the ISO image and
# can fail to find packages that exist in the current repos (e.g. nvidia).
pacman -Sy

pacstrap /mnt "${PACKAGES[@]}"
success "Base system installed"

# =============================================================================
# SECTION 6 — FSTAB
# fstab tells the system what to mount at boot and where.
# genfstab generates this automatically based on what's currently mounted.
# -U uses UUIDs instead of device names — UUIDs are stable across reboots.
# =============================================================================
section "Generating fstab"
genfstab -U /mnt >> /mnt/etc/fstab
success "fstab generated"

# --- Secondary HDD fstab entry ---
# genfstab only sees what's mounted right now, so the HDD won't be picked up
# automatically. We append its entry manually using the UUID and fstype we
# detected during the questions phase.
if [[ "$HDD" == true ]]; then
    echo "" >> /mnt/etc/fstab
    echo "# Secondary HDD" >> /mnt/etc/fstab
    echo "UUID=$HDD_UUID  $HDD_MOUNT  $HDD_FSTYPE  defaults  0  2" >> /mnt/etc/fstab
    success "Secondary HDD fstab entry added ($HDD_PART → $HDD_MOUNT)"
fi

info "fstab contents:"
cat /mnt/etc/fstab

# =============================================================================
# SECTION 7 — CHROOT CONFIGURATION
# arch-chroot changes root into the new system so we configure it as if
# we're running inside it. All commands from here run inside /mnt.
#
# Variables are expanded by the outer shell before the heredoc is sent in
# (note: no quotes around EOF). Escape \$ anywhere you need a literal dollar
# sign evaluated *inside* the chroot instead.
# =============================================================================
section "Entering chroot to configure system"

arch-chroot /mnt /bin/bash <<EOF

set -e

# Export config vars so configure.sh can read them without needing .baker-config,
# which hasn't been written yet at this point in the install.
export PROFILE=$PROFILE
export USERNAME=$USERNAME
export HOSTNAME=$HOSTNAME
export TIMEZONE=$TIMEZONE
export LOCALE=$LOCALE
export KEYMAP=$KEYMAP
export GPU=$GPU
export LUKS=$LUKS
export LUKS_UUID=$LUKS_UUID
export DUAL_BOOT=$DUAL_BOOT
export HDD=$HDD
export HDD_MOUNT=$HDD_MOUNT

# --- Passwords ---
echo "root:$ROOT_PASSWORD" | chpasswd
echo "Root password set"

# --- User ---
useradd -m -G wheel,audio,video,storage,input -s /bin/bash "$USERNAME"
echo "$USERNAME:$USER_PASSWORD" | chpasswd
echo "User $USERNAME created"

# --- Bootloader: GRUB install ---
# --target=x86_64-efi        — install for 64-bit UEFI
# --efi-directory=$EFI_MOUNT — where the EFI partition is mounted
# --bootloader-id=GRUB       — name that appears in the UEFI firmware menu
grub-install --target=x86_64-efi --efi-directory=$EFI_MOUNT --bootloader-id=GRUB --removable
echo "GRUB installed"

# --- Services ---
systemctl enable NetworkManager
systemctl enable sddm
systemctl enable ufw
systemctl enable sshd
systemctl enable tailscaled

if [[ "$PROFILE" == "laptop" ]]; then
    systemctl enable tlp
    systemctl enable bluetooth
fi

echo "Services enabled"

# --- System configuration ---
# configure.sh handles timezone, locale, keymap, hostname, sudo, mkinitcpio,
# GRUB config, and sshd hardening. It reads vars from the environment above.
curl -fsSL "$REPO_RAW/configure.sh" | bash

echo "Chroot complete."
EOF

success "Chroot configuration done"

# =============================================================================
# SECTION 8 — BAKER CONFIG
# Write ~/.baker-config to the new system. This is the permanent machine
# identity and config file — read by baker-update on every run.
# =============================================================================
section "Writing .baker-config"

LOCALE="en_GB.UTF-8"
KEYMAP="us"
BAKER_CONFIG="/mnt/home/$USERNAME/.baker-config"

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
GRUB_TIMEOUT=-1
NORD_COUNTRY=us

# --- Hardware (auto-detected, do not edit) ---
USERNAME=$USERNAME
PROFILE=$PROFILE
GPU=$GPU
BAKERCONF

# LUKS and HDD written separately so related keys stay grouped together
if [[ "$LUKS" == true ]]; then
    printf "LUKS=true\nLUKS_UUID=%s\n" "$LUKS_UUID" >> "$BAKER_CONFIG"
else
    echo "LUKS=false" >> "$BAKER_CONFIG"
fi

echo "DUAL_BOOT=$DUAL_BOOT" >> "$BAKER_CONFIG"

if [[ "$HDD" == true ]]; then
    printf "HDD=true\nHDD_MOUNT=%s\n" "$HDD_MOUNT" >> "$BAKER_CONFIG"
else
    echo "HDD=false" >> "$BAKER_CONFIG"
fi

if [[ "$PROFILE" == "laptop" && -n "$WIFI_SSID" ]]; then
    printf "\n# --- Temporary (stripped by post-install.sh after first boot) ---\nWIFI_SSID=%s\nWIFI_PASSWORD=%s\n" \
        "$WIFI_SSID" "$WIFI_PASSWORD" >> "$BAKER_CONFIG"
fi

success ".baker-config written"

# =============================================================================
# SECTION 9 — POST-INSTALL SCRIPT SETUP
# Download post-install.sh and post-reboot.sh to the new user's home directory
# so they're ready to run after first boot.
# =============================================================================
section "Downloading post-install scripts"

info "Downloading post-install.sh and post-reboot.sh..."
curl -fsSL "$REPO_RAW/post-install.sh" -o /mnt/home/"$USERNAME"/post-install.sh \
    || error "Failed to download post-install.sh"
curl -fsSL "$REPO_RAW/post-reboot.sh" -o /mnt/home/"$USERNAME"/post-reboot.sh \
    || error "Failed to download post-reboot.sh"
chmod +x /mnt/home/"$USERNAME"/post-install.sh
chmod +x /mnt/home/"$USERNAME"/post-reboot.sh
success "post-install.sh and post-reboot.sh downloaded to /home/$USERNAME/"

info "After first boot, run: bash ~/post-install.sh"
info "After post-install reboots, run: bash ~/post-reboot.sh"

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
