#!/bin/bash
#############################################################################
# Author: James Barrett | Company: Xinle, LLC
# Version: 11.0.0
# Created: March 11, 2025
# Last Modified: March 11, 2025
#############################################################################
#
#  Xinle 欣乐 — Master Infrastructure Setup Script & Bootstrapper
#
#  Single entry point for deploying the entire Xinle self-hosted
#  infrastructure stack on a fresh Ubuntu 24.04 LTS server. Run as root:
#
#    curl -fsSL https://raw.githubusercontent.com/XinleSA/rmmx/main/scripts/01_master_setup.sh | sudo bash
#
#  What this script does (in order):
#    0.  Pre-flight cleanup of any previous failed installation traces
#    1.  Clone the repository from GitHub (bootstrap)
#    2.  Create the 'sar' service user and hand off execution
#    3.  Validate .env file exists and has no unfilled placeholder values
#    4.  Configure timezone (America/Chicago), NTP (us.pool.ntp.org), CIFS/NFS
#    5.  Install Docker CE + Docker Compose plugin
#    6.  Install and configure Grafana Alloy metrics agent
#    7.  Create /docker_apps directory structure
#    8.  Configure IPsec site-to-site VPN (strongSwan)
#    9.  Seed NetLock RMM configuration files
#   10.  Pull and start all Docker services
#   11.  Print deployment summary with VPN credentials
#############################################################################

set -euo pipefail

# --- Configuration ---
readonly GITHUB_REPO="XinleSA/rmmx"
readonly PROJECT_DEST="/home/ubuntu/xinle-infra"
readonly DOCKER_APPS_DIR="/docker_apps"
readonly TARGET_USER="sar"
readonly PSK_FILE="/etc/ipsec.d/psk.txt"

# --- State Tracking for Rollback ---
STATE_REPO_CLONED=false
STATE_USER_CREATED=false
STATE_DOCKER_INSTALLED=false
STATE_ALLOY_INSTALLED=false
STATE_DOCKER_DIR_CREATED=false
STATE_IPSEC_INSTALLED=false
STATE_DOCKER_COMPOSE_UP=false

# --- Helper Functions ---
print_header() { echo -e "\n\e[1;35m##############################################################################\e[0m"; echo -e "\e[1;35m  $1\e[0m"; echo -e "\e[1;35m##############################################################################\e[0m"; }
print_info()   { echo -e "\e[1;36m  [INFO]  $1\e[0m"; }
print_ok()     { echo -e "\e[1;32m  [OK]    $1\e[0m"; }
print_warn()   { echo -e "\e[1;33m  [WARN]  $1\e[0m"; }
print_error()  { echo -e "\e[1;31m  [ERROR] $1\e[0m" >&2; }

# --- Pre-flight Cleanup ---
pre_flight_cleanup() {
    print_header "Pre-flight Cleanup"
    print_info "Checking for traces of previous failed installations..."
    local traces_found=false

    if id -u "$TARGET_USER" >/dev/null 2>&1; then
        print_warn "Found existing user '$TARGET_USER'. Removing..."
        deluser --remove-home "$TARGET_USER" || true
        traces_found=true
    fi
    if [ -d "$PROJECT_DEST" ]; then
        print_warn "Found existing repository at $PROJECT_DEST. Removing..."
        rm -rf "$PROJECT_DEST" || true
        traces_found=true
    fi
    if [ -d "$DOCKER_APPS_DIR" ]; then
        print_warn "Found existing Docker directory at $DOCKER_APPS_DIR. Removing..."
        rm -rf "$DOCKER_APPS_DIR" || true
        traces_found=true
    fi
    if dpkg-query -W -f='${Status}' docker-ce 2>/dev/null | grep -q "install ok installed"; then
        print_warn "Found existing Docker installation. Purging..."
        apt-get --allow-remove-essential -y purge docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin || true
        rm -rf /var/lib/docker /etc/docker || true
        traces_found=true
    fi

    if [ "$traces_found" = false ]; then
        print_ok "No traces found. System is clean."
    else
        print_ok "Cleanup complete."
    fi
}

# --- Rollback ---
rollback() {
    local exit_code=$?
    if [ $exit_code -eq 0 ]; then return; fi

    print_header "ROLLBACK INITIATED — An error occurred. Undoing all changes..."

    if [ "$STATE_DOCKER_COMPOSE_UP" = true ]; then
        print_info "Stopping and removing all Docker containers..."
        (cd "$PROJECT_DEST" && docker compose down -v --remove-orphans) || true
    fi
    if [ "$STATE_IPSEC_INSTALLED" = true ]; then
        print_info "Uninstalling IPsec (strongSwan)..."
        systemctl stop ipsec || true
        systemctl stop xfrm0-interface.service || true
        systemctl disable xfrm0-interface.service || true
        apt-get purge -y strongswan strongswan-starter || true
        rm -rf /etc/ipsec.conf /etc/ipsec.secrets /etc/ipsec.d || true
        rm -f /etc/systemd/system/xfrm0-interface.service || true
        ip link del xfrm0 2>/dev/null || true
        sed -i '/# Xinle xfrm0 FORWARD rules/,/^-A FORWARD -o xfrm0 -j ACCEPT/d' \
            /etc/ufw/before.rules 2>/dev/null || true
        systemctl daemon-reload || true
    fi
    if [ "$STATE_DOCKER_DIR_CREATED" = true ]; then
        print_info "Removing Docker application directory $DOCKER_APPS_DIR..."
        rm -rf "$DOCKER_APPS_DIR" || true
    fi
    if [ "$STATE_ALLOY_INSTALLED" = true ]; then
        print_info "Uninstalling Grafana Alloy..."
        systemctl stop alloy || true
        apt-get purge -y alloy || true
        rm -rf /etc/alloy /etc/apt/sources.list.d/grafana.list || true
    fi
    if [ "$STATE_DOCKER_INSTALLED" = true ]; then
        print_info "Uninstalling Docker..."
        apt-get --allow-remove-essential -y purge docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin || true
        rm -rf /var/lib/docker /etc/docker /etc/apt/sources.list.d/docker.list || true
    fi
    if [ "$STATE_USER_CREATED" = true ]; then
        print_info "Deleting user '$TARGET_USER'..."
        deluser --remove-home "$TARGET_USER" || true
    fi
    if [ "$STATE_REPO_CLONED" = true ]; then
        print_info "Removing cloned repository at $PROJECT_DEST..."
        rm -rf "$PROJECT_DEST" || true
    fi

    print_header "ROLLBACK COMPLETE"
    exit $exit_code
}

trap rollback ERR

# =============================================================================
#  Stage 0: Pre-flight Root Check & Cleanup
# =============================================================================
if [ "${1:-}" != "--bootstrapped" ]; then
    if [ "$(id -u)" -ne 0 ]; then
        print_error "This script must be run as root or with sudo."
        exit 1
    fi
    pre_flight_cleanup
fi

# =============================================================================
#  Stage 1: Bootstrap — Clone repo and re-exec from within it
# =============================================================================
if [ ! -d "$PROJECT_DEST" ]; then
    print_header "Stage 1: Bootstrap"
    print_info "Git repository not found. Cloning from GitHub..."
    if ! command -v git &> /dev/null; then
        apt-get update -qq && apt-get install -y git
    fi
    git clone "https://github.com/${GITHUB_REPO}.git" "$PROJECT_DEST"
    STATE_REPO_CLONED=true
    print_info "Repository cloned. Re-executing from within the repository..."
    exec bash "${PROJECT_DEST}/scripts/01_master_setup.sh" --bootstrapped
fi

# =============================================================================
#  Stage 2: User Creation & Handoff (runs as root)
# =============================================================================
if [ "$(whoami)" == "root" ]; then
    print_header "Stage 2: User Creation & Handoff"

    if ! id -u "$TARGET_USER" >/dev/null 2>&1; then
        useradd -m -s /bin/bash -G sudo "$TARGET_USER"
        print_info "User '$TARGET_USER' created. Set a password with: passwd $TARGET_USER"
    else
        print_info "User '$TARGET_USER' already exists."
    fi
    STATE_USER_CREATED=true

    getent group docker >/dev/null || groupadd docker
    usermod -aG docker "$TARGET_USER"
    chown -R "$TARGET_USER":"$TARGET_USER" "$PROJECT_DEST"

    print_info "Handing off execution to user '$TARGET_USER'..."
    exec sudo -u "$TARGET_USER" -H bash "${PROJECT_DEST}/scripts/01_master_setup.sh" --bootstrapped
fi

# =============================================================================
#  Stage 3: Main Infrastructure Setup (runs as TARGET_USER)
# =============================================================================
if [ "$(whoami)" != "$TARGET_USER" ]; then
    print_error "Stage 3 must run as '$TARGET_USER' but is running as '$(whoami)'. Aborting."
    exit 1
fi

print_header "Stage 3: Main Infrastructure Setup (as ${TARGET_USER})"
cd "$PROJECT_DEST"

print_info "Pulling latest changes from GitHub..."
git pull origin main --rebase

# ---------------------------------------------------------------------------
#  Validate .env file
# ---------------------------------------------------------------------------
print_header "Validating .env Configuration"

if [ ! -f "${PROJECT_DEST}/.env" ]; then
    print_error ".env file not found at ${PROJECT_DEST}/.env"
    print_error "Please create it from the template: cp .env.example .env"
    print_error "Then fill in all required values before running this script."
    exit 1
fi

# Check for any unfilled placeholder values
if grep -qE "^[^#].*your_" "${PROJECT_DEST}/.env"; then
    print_error "Your .env file still contains unfilled placeholder values:"
    grep -E "^[^#].*your_" "${PROJECT_DEST}/.env" | sed 's/=.*/=<REDACTED>/' || true
    print_error "Please fill in all values in .env before proceeding."
    exit 1
fi

# Source the .env so we can use variables in this script
set -a
# shellcheck disable=SC1091
source "${PROJECT_DEST}/.env"
set +a

print_ok ".env validated successfully."

# ---------------------------------------------------------------------------
#  System Configuration — Timezone, NTP, Share Support
# ---------------------------------------------------------------------------
print_header "Configuring Timezone, NTP, and Share Support"

sudo timedatectl set-timezone "America/Chicago"

sudo apt-get update -qq
sudo apt-get install -y cifs-utils nfs-common

# Use systemd-timesyncd (correct for Ubuntu 22.04+) instead of legacy ntp package
sudo mkdir -p /etc/systemd/timesyncd.conf.d
cat << 'NTP_EOF' | sudo tee /etc/systemd/timesyncd.conf.d/xinle-ntp.conf > /dev/null
[Time]
NTP=us.pool.ntp.org
FallbackNTP=pool.ntp.org
NTP_EOF

sudo timedatectl set-ntp true
sudo systemctl restart systemd-timesyncd

print_ok "Timezone (America/Chicago), NTP (us.pool.ntp.org), CIFS, and NFS support configured."
timedatectl status

# ---------------------------------------------------------------------------
#  Docker Installation
# ---------------------------------------------------------------------------
print_header "Installing Docker CE and Docker Compose Plugin"

if ! command -v docker &> /dev/null; then
    sudo apt-get install -y ca-certificates curl
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
      https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update -qq
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
fi

STATE_DOCKER_INSTALLED=true
print_ok "Docker is installed and running."

# ---------------------------------------------------------------------------
#  Grafana Alloy (Metrics Agent)
# ---------------------------------------------------------------------------
print_header "Installing Grafana Alloy for Metrics Collection"

sudo mkdir -p /etc/alloy
sudo cp "$PROJECT_DEST/monitoring/alloy-config.alloy" /etc/alloy/config.alloy

if ! command -v alloy &> /dev/null; then
    sudo apt-get install -y wget gpg
    wget -qO- https://apt.grafana.com/gpg.key | \
        gpg --dearmor | sudo tee /usr/share/keyrings/grafana.gpg > /dev/null
    echo "deb [signed-by=/usr/share/keyrings/grafana.gpg] https://apt.grafana.com stable main" | \
        sudo tee /etc/apt/sources.list.d/grafana.list
    sudo apt-get update -qq
    sudo apt-get install -y alloy
fi

sudo chown -R alloy:alloy /etc/alloy
sudo systemctl enable alloy
sudo systemctl start alloy
STATE_ALLOY_INSTALLED=true
print_ok "Grafana Alloy installed and configured."

# ---------------------------------------------------------------------------
#  Docker Application Directory
# ---------------------------------------------------------------------------
print_header "Creating Docker Application Directory"

sudo mkdir -p "$DOCKER_APPS_DIR"
sudo chown -R "$TARGET_USER":"$TARGET_USER" "$DOCKER_APPS_DIR"
STATE_DOCKER_DIR_CREATED=true
print_ok "Directory $DOCKER_APPS_DIR created and owned by ${TARGET_USER}."

# ---------------------------------------------------------------------------
#  IPsec Site-to-Site VPN
# ---------------------------------------------------------------------------
print_header "Setting up IPsec Site-to-Site VPN"

sudo chmod +x "$PROJECT_DEST/scripts/05_setup_ipsec_vpn.sh"
sudo "$PROJECT_DEST/scripts/05_setup_ipsec_vpn.sh"
STATE_IPSEC_INSTALLED=true

# ---------------------------------------------------------------------------
#  NetLock RMM Configuration Seeding
# ---------------------------------------------------------------------------
print_header "Seeding NetLock RMM Configuration"

sudo mkdir -p /docker_apps/netlockrmm/server/internal
sudo mkdir -p /docker_apps/netlockrmm/server/files
sudo mkdir -p /docker_apps/netlockrmm/server/logs
sudo mkdir -p /docker_apps/netlockrmm/web

if [ ! -f /docker_apps/netlockrmm/server/appsettings.json ]; then
    # Substitute MYSQL_PASSWORD from .env into the appsettings template
    sed "s|\${MYSQL_PASSWORD}|${MYSQL_PASSWORD}|g" \
        "$PROJECT_DEST/scripts/netlock-server-appsettings.json" | \
        sudo tee /docker_apps/netlockrmm/server/appsettings.json > /dev/null
    print_ok "Seeded NetLock RMM server appsettings.json"
fi

if [ ! -f /docker_apps/netlockrmm/web/appsettings.json ]; then
    sudo cp "$PROJECT_DEST/scripts/netlock-web-appsettings.json" \
        /docker_apps/netlockrmm/web/appsettings.json
    print_ok "Seeded NetLock RMM web console appsettings.json"
fi

sudo chown -R "$TARGET_USER":"$TARGET_USER" /docker_apps/netlockrmm
print_ok "NetLock RMM configuration directories ready."

# ---------------------------------------------------------------------------
#  pgAdmin directory ownership fix
# ---------------------------------------------------------------------------
print_header "Preparing pgAdmin Data Directory"
sudo mkdir -p /docker_apps/pgadmin
sudo chown -R 5050:5050 /docker_apps/pgadmin
print_ok "pgAdmin data directory owned by UID 5050."

# ---------------------------------------------------------------------------
#  Start All Docker Services
# ---------------------------------------------------------------------------
print_header "Pulling Docker Images"
cd "$PROJECT_DEST"

while IFS= read -r service; do
    print_info "Pulling image for: ${service}"
    sudo docker compose pull "$service" 2>&1 || \
        print_warn "Could not pull latest image for '${service}'. Using cached version if available."
done < <(sudo docker compose config --services)

print_header "Starting All Docker Services"
sudo docker compose up -d
STATE_DOCKER_COMPOSE_UP=true
print_ok "All Docker services started."

# ---------------------------------------------------------------------------
#  Deployment Summary
# ---------------------------------------------------------------------------
VPS_PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || echo "<VPS_IP>")
VPN_PSK=$(cat "${PSK_FILE}" 2>/dev/null || echo "<see /etc/ipsec.d/psk.txt>")

print_header "DEPLOYMENT COMPLETE"
echo ""
echo -e "\e[1;32m  All services are running. Complete the following steps to finish setup:\e[0m"
echo ""
echo "  ┌─────────────────────────────────────────────────────────────────────┐"
echo "  │  STEP 1 — Cloudflare DNS                                            │"
echo "  │  Add an A record: rmmx.xinle.biz → ${VPS_PUBLIC_IP}                │"
echo "  │  Set proxy status to DNS Only (grey cloud) initially.               │"
echo "  ├─────────────────────────────────────────────────────────────────────┤"
echo "  │  STEP 2 — UDM Pro Site-to-Site VPN (UniFi → Settings → Networks)   │"
echo "  │                                                                     │"
echo "  │  Pre-Shared Key : ${VPN_PSK}                                        │"
echo "  │  Server Address : ${VPS_PUBLIC_IP}  (Remote Host = VPS)             │"
echo "  │  Remote Subnets : 172.20.0.0/16   (VPS Docker network)             │"
echo "  │  Local Subnets  : 10.1.0.0/24     (UDM Pro LAN)                   │"
echo "  │  IKE Version    : IKEv2                                             │"
echo "  │  Encryption     : AES-256                                           │"
echo "  │  Hash           : SHA-256                                           │"
echo "  │  DH Group       : 14 (2048-bit MODP)                               │"
echo "  │  PFS            : Enabled (Group 14)                                │"
echo "  │                                                                     │"
echo "  │  NOTE: The UDM Pro must INITIATE the tunnel. The VPS listens.      │"
echo "  │  Verify: sudo ipsec status && ping -c 3 10.1.0.1                   │"
echo "  ├─────────────────────────────────────────────────────────────────────┤"
echo "  │  STEP 3 — Nginx Proxy Manager                                       │"
echo "  │  Access at: http://${VPS_PUBLIC_IP}:81                              │"
echo "  │  Default login: admin@example.com / changeme                        │"
echo "  │  See docs/POST_INSTALL_RUNBOOK.md for full NPM configuration.       │"
echo "  └─────────────────────────────────────────────────────────────────────┘"
echo ""
echo "  Full runbook: ${PROJECT_DEST}/docs/POST_INSTALL_RUNBOOK.md"
echo ""

trap - ERR
exit 0
