#!/bin/bash
# =============================================================================
#  Xinle 欣乐 — Master Infrastructure Setup Script & Bootstrapper
# =============================================================================
#  Version: 9.10
#
#  This script is the single entry point for deploying the entire Xinle
#  self-hosted infrastructure stack on a fresh Ubuntu 24.04.4 LTS server.
#
#  FIX in 9.7:  Infinite loop fix — --bootstrapped flag prevents re-running
#               pre-flight cleanup on exec handoff. Precise Docker detection.
#  FIX in 9.8:  IPsec rollback uses correct 'ipsec' service name on Ubuntu 24.04.
#  FIX in 9.9:  Correct NetLock RMM image names, appsettings format, and
#               directory seeding before docker compose up.
#  FIX in 9.10: IPsec rollback also purges iptables-persistent, stops
#               xfrm0-interface.service, and deletes the xfrm0 link.
# =============================================================================

set -e

# --- Configuration ---
readonly GITHUB_REPO="XinleSA/rmmx"
readonly PROJECT_DEST="/home/ubuntu/xinle-infra"
readonly DOCKER_APPS_DIR="/docker_apps"
readonly TARGET_USER="sar"
readonly TARGET_PASS="tb,Xinle2026!"

# --- State Tracking for Rollback ---
STATE_REPO_CLONED=false
STATE_USER_CREATED=false
STATE_DOCKER_INSTALLED=false
STATE_ALLOY_INSTALLED=false
STATE_DOCKER_DIR_CREATED=false
STATE_IPSEC_INSTALLED=false
STATE_DOCKER_COMPOSE_UP=false

# --- Helper Functions ---
print_header() { echo -e "\n\e[1;35m--- $1 ---\e[0m"; }
print_info()   { echo -e "\e[1;36m  $1\e[0m"; }
print_warn()   { echo -e "\e[1;33m  WARNING: $1\e[0m"; }
print_error()  { echo -e "\e[1;31m  ERROR: $1\e[0m" >&2; }

# --- Pre-flight Cleanup Function ---
pre_flight_cleanup() {
    print_header "Pre-flight Cleanup"
    print_info "Checking for traces of previous failed installations..."
    local traces_found=false

    if id -u "$TARGET_USER" >/dev/null 2>&1; then
        print_warn "Found existing user '$TARGET_USER'. Removing..."
        sudo deluser --remove-home "$TARGET_USER" || true
        traces_found=true
    fi
    if [ -d "$PROJECT_DEST" ]; then
        print_warn "Found existing repository at $PROJECT_DEST. Removing..."
        sudo rm -rf "$PROJECT_DEST" || true
        traces_found=true
    fi
    if [ -d "$DOCKER_APPS_DIR" ]; then
        print_warn "Found existing Docker directory at $DOCKER_APPS_DIR. Removing..."
        sudo rm -rf "$DOCKER_APPS_DIR" || true
        traces_found=true
    fi
    # Use a precise check for the docker-ce package
    if dpkg-query -W -f='${Status}' docker-ce 2>/dev/null | grep -q "install ok installed"; then
        print_warn "Found existing Docker installation. Purging..."
        sudo apt-get --allow-remove-essential -y purge docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || true
        sudo rm -rf /var/lib/docker /etc/docker || true
        traces_found=true
    fi

    if [ "$traces_found" = false ]; then
        print_info "No traces found. System is clean."
    else
        print_info "Cleanup complete."
    fi
}

# --- Rollback Function ---
rollback() {
    local exit_code=$?
    if [ $exit_code -eq 0 ]; then return; fi

    print_header "ROLLBACK INITIATED — An error occurred. Undoing all changes..."

    if [ "$STATE_DOCKER_COMPOSE_UP" = true ]; then
        print_info "Stopping and removing all Docker containers..."
        (cd "$PROJECT_DEST" && sudo docker compose down -v --remove-orphans) || true
    fi
    if [ "$STATE_IPSEC_INSTALLED" = true ]; then
        print_info "Uninstalling IPsec (strongSwan)..."
        sudo systemctl stop ipsec || true
        sudo systemctl stop xfrm0-interface.service || true
        sudo systemctl disable xfrm0-interface.service || true
        sudo apt-get purge -y strongswan strongswan-starter iptables-persistent || true
        sudo rm -rf /etc/ipsec.conf /etc/ipsec.secrets /etc/ipsec.d || true
        sudo rm -f /etc/systemd/system/xfrm0-interface.service || true
        sudo ip link del xfrm0 2>/dev/null || true
        sudo systemctl daemon-reload || true
    fi
    if [ "$STATE_DOCKER_DIR_CREATED" = true ]; then
        print_info "Removing Docker application directory $DOCKER_APPS_DIR..."
        sudo rm -rf "$DOCKER_APPS_DIR" || true
    fi
    if [ "$STATE_ALLOY_INSTALLED" = true ]; then
        print_info "Uninstalling Grafana Alloy..."
        sudo systemctl stop alloy || true
        sudo apt-get purge -y alloy || true
        sudo rm -rf /etc/alloy /etc/apt/sources.list.d/grafana.list || true
    fi
    if [ "$STATE_DOCKER_INSTALLED" = true ]; then
        print_info "Uninstalling Docker..."
        sudo apt-get --allow-remove-essential -y purge docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || true
        sudo rm -rf /var/lib/docker /etc/docker /etc/apt/sources.list.d/docker.list || true
    fi
    if [ "$STATE_USER_CREATED" = true ]; then
        print_info "Deleting user '$TARGET_USER'..."
        sudo deluser --remove-home "$TARGET_USER" || true
    fi
    if [ "$STATE_REPO_CLONED" = true ]; then
        print_info "Removing cloned repository at $PROJECT_DEST..."
        sudo rm -rf "$PROJECT_DEST" || true
    fi

    print_header "ROLLBACK COMPLETE"
    exit $exit_code
}

trap rollback ERR

# --- Stage 0: Pre-flight Root Check & Cleanup ---
if [ "$1" != "--bootstrapped" ]; then
    if [ "$(id -u)" -ne 0 ]; then
        print_error "This script must be run as root or with sudo. Please use: curl ... | sudo bash"
        exit 1
    fi
    pre_flight_cleanup
fi

# --- Stage 1: Bootstrap (run as root) ---
if [ ! -d "$PROJECT_DEST" ]; then
    print_header "Stage 1: Bootstrap"
    print_info "Bootstrapper mode: Git repository not found. Cloning from GitHub..."
    if ! command -v git &> /dev/null; then
        apt-get update -qq && apt-get install -y git
    fi
    git clone "https://github.com/${GITHUB_REPO}.git" "$PROJECT_DEST"
    STATE_REPO_CLONED=true
    print_info "Repository cloned. Re-executing script from within the repository... (passing --bootstrapped flag)"
    exec bash "${PROJECT_DEST}/scripts/01_master_setup.sh" --bootstrapped
fi

# --- Stage 2: User Creation & Handoff (run as root) ---
if [ "$(whoami)" == "root" ]; then
    print_header "Stage 2: User Creation & Handoff"

    print_info "Creating user '$TARGET_USER'..."
    if ! id -u "$TARGET_USER" >/dev/null 2>&1; then
        useradd -m -s /bin/bash -G sudo "$TARGET_USER"
        echo "${TARGET_USER}:${TARGET_PASS}" | chpasswd
        STATE_USER_CREATED=true
        print_info "User '$TARGET_USER' created with password."
    else
        print_info "User '$TARGET_USER' already exists."
        STATE_USER_CREATED=true # Assume it's ours if it exists
    fi

    print_info "Adding '$TARGET_USER' to the 'docker' group..."
    getent group docker >/dev/null || groupadd docker
    usermod -aG docker "$TARGET_USER"

    print_info "Transferring repository ownership to '$TARGET_USER'..."
    chown -R "$TARGET_USER":"$TARGET_USER" "$PROJECT_DEST"

    print_info "Handing off execution to user '$TARGET_USER'..."
    exec sudo -u "$TARGET_USER" -H bash "${PROJECT_DEST}/scripts/01_master_setup.sh" --bootstrapped
fi

# --- Stage 3: Main Infrastructure Setup (run as TARGET_USER) ---
if [ "$(whoami)" != "$TARGET_USER" ]; then
    print_error "This stage must be run as user '$TARGET_USER', but is running as '$(whoami)'. Aborting."
    exit 1
fi

print_header "Stage 3: Main Infrastructure Setup (as ${TARGET_USER})"
cd "$PROJECT_DEST"

print_info "Pulling latest changes from GitHub..."
git pull origin main --rebase

# --- System Configuration ---
print_header "Configuring Timezone, NTP, and Share Support"
sudo timedatectl set-timezone "America/Chicago"
sudo apt-get update -qq
sudo apt-get install -y ntp cifs-utils nfs-common
sudo systemctl restart ntp
print_info "Timezone, NTP, CIFS, and NFS support configured."

# --- Docker Installation ---
print_header "Installing Docker and Docker Compose"
if ! command -v docker &> /dev/null; then
    sudo apt-get install -y ca-certificates curl
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update -qq
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
STATE_DOCKER_INSTALLED=true
print_info "Docker is installed and running."

# --- Grafana Alloy (Metrics Agent) Installation ---
print_header "Installing Grafana Alloy for Metrics Collection"
sudo mkdir -p /etc/alloy
sudo cp "$PROJECT_DEST/monitoring/alloy-config.river" /etc/alloy/config.river

if ! command -v alloy &> /dev/null; then
    sudo apt-get install -y wget
    wget -qO- https://apt.grafana.com/gpg.key | gpg --dearmor | sudo tee /usr/share/keyrings/grafana.gpg > /dev/null
    echo "deb [signed-by=/usr/share/keyrings/grafana.gpg] https://apt.grafana.com stable main" | sudo tee /etc/apt/sources.list.d/grafana.list
    sudo apt-get update -qq
    sudo apt-get install -y alloy
fi

sudo chown -R alloy:alloy /etc/alloy
sudo systemctl enable alloy
sudo systemctl start alloy
STATE_ALLOY_INSTALLED=true
print_info "Grafana Alloy installed and configured to send metrics to fenix.xinle.biz."

# --- Create Docker Application Directory ---
print_header "Creating Docker Application Directory"
sudo mkdir -p "$DOCKER_APPS_DIR"
sudo chown -R "$TARGET_USER":"$TARGET_USER" "$DOCKER_APPS_DIR"
STATE_DOCKER_DIR_CREATED=true
print_info "Directory $DOCKER_APPS_DIR created and owned by ${TARGET_USER}."

# --- Set up IPsec Site-to-Site VPN ---
print_header "Setting up IPsec Site-to-Site VPN"
sudo chmod +x "$PROJECT_DEST/scripts/05_setup_ipsec_vpn.sh"
sudo "$PROJECT_DEST/scripts/05_setup_ipsec_vpn.sh"
STATE_IPSEC_INSTALLED=true

# --- Seed NetLock RMM Configuration Files ---
print_header "Seeding NetLock RMM Configuration"
sudo mkdir -p /docker_apps/netlockrmm/server/internal
sudo mkdir -p /docker_apps/netlockrmm/server/files
sudo mkdir -p /docker_apps/netlockrmm/server/logs
sudo mkdir -p /docker_apps/netlockrmm/web
# Only seed the appsettings if they don't already exist (preserve user edits)
if [ ! -f /docker_apps/netlockrmm/server/appsettings.json ]; then
    sudo cp "$PROJECT_DEST/scripts/netlock-server-appsettings.json" /docker_apps/netlockrmm/server/appsettings.json
    print_info "Seeded NetLock RMM server appsettings.json"
fi
if [ ! -f /docker_apps/netlockrmm/web/appsettings.json ]; then
    sudo cp "$PROJECT_DEST/scripts/netlock-web-appsettings.json" /docker_apps/netlockrmm/web/appsettings.json
    print_info "Seeded NetLock RMM web console appsettings.json"
fi
sudo chown -R "$TARGET_USER":"$TARGET_USER" /docker_apps/netlockrmm
print_info "NetLock RMM configuration directories ready."

# --- Start All Docker Services ---
print_header "Starting All Docker Services"
cd "$PROJECT_DEST"

print_info "Pulling latest images for all services... (This may take a while)"
sudo docker compose pull

print_info "Starting containers in detached mode..."
sudo docker compose up -d
STATE_DOCKER_COMPOSE_UP=true

print_info "Docker services started."

# --- Final Instructions ---
print_header "DEPLOYMENT COMPLETE — ACTION REQUIRED"
echo ""
echo "  The core infrastructure is now running under user '$TARGET_USER'."
echo "  1.  **Configure UDM Pro VPN:** Use the IPsec parameters printed above."
echo "  2.  **Configure Nginx Proxy Manager:** Access at http://$(curl -s ifconfig.me):81."
echo "  3.  **Check Grafana:** Your new dashboards should appear in Grafana at https://fenix.xinle.biz/grafana shortly."
echo ""

# --- Disable Rollback Trap on Successful Exit ---
trap - ERR
exit 0
