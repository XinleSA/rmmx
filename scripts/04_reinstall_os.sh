#!/bin/bash
#############################################################################
# Author: James Barrett | Company: Xinle, LLC
# Version: 6.1.0
# Created: March 11, 2025
# Last Modified: March 11, 2025
#############################################################################
#
#  Xinle 欣乐 — Remote OS Reinstallation Script
#
#  Completely and irrevocably reinstalls the operating system on this server
#  to a fresh Ubuntu 24.04.4 LTS (Noble Numbat), directly from an active
#  SSH session — no control panel access required.
#
#  HOW IT WORKS
#  ─────────────────────────────────────────────────────────────────────────────
#  1. Downloads the Ubuntu 24.04 netboot kernel and initrd.
#  2. Generates a preseed.cfg with your static network settings.
#  3. Adds a custom GRUB entry pointing to the installer.
#  4. Sets that entry as the default boot option.
#  5. On next reboot, the server boots into the automated installer,
#     wipes the disk, installs Ubuntu 24.04.4, then reboots into the new OS.
#
#  WARNING: THIS IS EXTREMELY DESTRUCTIVE. IT WILL ERASE THE ENTIRE DISK.
#############################################################################

set -euo pipefail

# --- Configuration ---
readonly GITHUB_REPO="XinleSA/rmmx"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
readonly UBUNTU_CODENAME="noble"
readonly UBUNTU_VERSION="24.04.4"
readonly INSTALLER_DIR="/boot/installer"

# --- Helper Functions ---
print_header() { echo -e "\n\e[1;35m--- $1 ---\e[0m"; }
print_info()   { echo -e "\e[1;36m  $1\e[0m"; }
print_warn()   { echo -e "\e[1;33m  WARNING: $1\e[0m"; }

# =============================================================================
# STAGE 1: Self-Update from GitHub
# =============================================================================
print_header "Checking for Script Updates from GitHub"

if [ -d "$PROJECT_ROOT/.git" ]; then
    cd "$PROJECT_ROOT"
    git pull origin main --rebase
    print_info "Repository is up to date."
    cd "$SCRIPT_DIR"
else
    print_info "Not a git repository. Skipping self-update."
fi

# =============================================================================
# STAGE 2: Safety Confirmation
# =============================================================================
print_header "CRITICAL WARNING — DESTRUCTIVE ACTION"
echo ""
echo -e "\e[1;31m  THIS SCRIPT WILL COMPLETELY AND IRREVOCABLY ERASE ALL DATA ON THIS SERVER.\e[0m"
echo ""
echo "  It will:"
echo "    - Format the primary disk"
echo "    - Install a fresh copy of Ubuntu ${UBUNTU_VERSION} LTS"
echo "    - Destroy all Docker containers, volumes, and databases"
echo "    - Destroy all configuration files"
echo ""
echo "  Before proceeding, ensure you have backed up /docker_apps and any other data."
echo ""
read -p "  To proceed, type exactly: ERASE MY SERVER  > " CONFIRMATION
echo ""

if [ "$CONFIRMATION" != "ERASE MY SERVER" ]; then
    echo "  Confirmation failed. Aborting — no changes were made."
    exit 1
fi

# =============================================================================
# STAGE 3: Detect Network Configuration
# =============================================================================
print_header "Detecting Network Configuration"

# Detect the primary network interface
PRIMARY_IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
IP_ADDR=$(ip -4 addr show "$PRIMARY_IFACE" | grep -oP 'inet \K[\d.]+')
PREFIX=$(ip -4 addr show "$PRIMARY_IFACE" | grep -oP 'inet [\d.]+/\K\d+')
GATEWAY=$(ip route | grep default | awk '{print $3}' | head -1)

# Convert CIDR prefix to dotted netmask
python3 -c "
import ipaddress
n = ipaddress.IPv4Network('0.0.0.0/${PREFIX}', strict=False)
print(str(n.netmask))
" > /tmp/netmask.txt
NETMASK=$(cat /tmp/netmask.txt)

print_info "Interface:  $PRIMARY_IFACE"
print_info "IP Address: $IP_ADDR"
print_info "Netmask:    $NETMASK"
print_info "Gateway:    $GATEWAY"
print_info "DNS:        1.1.1.1 8.8.8.8"
echo ""
read -p "  Are these network settings correct? (yes/no): " NET_CONFIRM
if [ "$NET_CONFIRM" != "yes" ]; then
    echo "  Please edit this script to set network values manually. Aborting."
    exit 1
fi

# =============================================================================
# STAGE 4: Download Ubuntu 24.04.4 Netboot Installer
# =============================================================================
print_header "Downloading Ubuntu ${UBUNTU_VERSION} Netboot Installer"

mkdir -p "$INSTALLER_DIR"
cd "$INSTALLER_DIR"

NETBOOT_BASE="http://archive.ubuntu.com/ubuntu/dists/${UBUNTU_CODENAME}/main/installer-amd64/current/images/netboot/ubuntu-installer/amd64"

print_info "Downloading kernel (linux)..."
wget -q --show-progress "${NETBOOT_BASE}/linux" -O "${INSTALLER_DIR}/linux"

print_info "Downloading initrd (initrd.gz)..."
wget -q --show-progress "${NETBOOT_BASE}/initrd.gz" -O "${INSTALLER_DIR}/initrd.gz"

print_info "Netboot installer downloaded."

# =============================================================================
# STAGE 5: Generate Preseed Configuration
# =============================================================================
print_header "Generating Preseed Configuration"

sed -e "s/{{IP_ADDRESS}}/${IP_ADDR}/g" \
    -e "s/{{NETMASK}}/${NETMASK}/g" \
    -e "s/{{GATEWAY}}/${GATEWAY}/g" \
    -e "s/{{NAMESERVERS}}/1.1.1.1 8.8.8.8/g" \
    "${SCRIPT_DIR}/preseed.cfg.template" > "${INSTALLER_DIR}/preseed.cfg"

print_info "Preseed configuration written to ${INSTALLER_DIR}/preseed.cfg"

# =============================================================================
# STAGE 6: Configure GRUB
# =============================================================================
print_header "Configuring GRUB Boot Entry"

cat > /etc/grub.d/40_xinle_reinstall << 'GRUBEOF'
#!/bin/sh
exec tail -n +3 $0
menuentry "Xinle — Reinstall Ubuntu 24.04.4 LTS" {
    set root=(hd0,1)
    linux /boot/installer/linux auto=true priority=critical \
        preseed/file=/boot/installer/preseed.cfg \
        netcfg/get_hostname=xinle-vps \
        netcfg/get_domain=xinle.biz \
        -- quiet
    initrd /boot/installer/initrd.gz
}
GRUBEOF

chmod +x /etc/grub.d/40_xinle_reinstall

# Set the installer as the one-time default boot entry
sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT="Xinle — Reinstall Ubuntu 24.04.4 LTS"/' /etc/default/grub
update-grub

print_info "GRUB configured. Installer will run on next reboot."

# =============================================================================
# STAGE 7: Final Instructions
# =============================================================================
print_header "READY TO REINSTALL"
echo ""
echo -e "\e[1;32m  The server is now prepared for reinstallation.\e[0m"
echo ""
echo "  What happens next:"
echo "    1. You type 'reboot' and press Enter."
echo "    2. The server boots into the Ubuntu ${UBUNTU_VERSION} automated installer."
echo "    3. The installer erases the disk and installs Ubuntu ${UBUNTU_VERSION} (~10-20 min)."
echo "    4. The server reboots again into the new OS."
echo "    5. SSH back in and run the master setup script:"
echo ""
echo "       curl -fsSL https://raw.githubusercontent.com/${GITHUB_REPO}/main/scripts/01_master_setup.sh | sudo bash"
echo ""
print_warn "You will need to retrieve the new root password from the ServerOptima portal after install."
echo ""
echo -e "  When ready, type \e[1;31mreboot\e[0m and press Enter."
echo ""

exit 0
