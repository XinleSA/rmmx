#!/bin/bash
#############################################################################
# Author: James Barrett | Company: Xinle, LLC
# Version: 12.3.0
# Created: March 11, 2025
# Last Modified: March 11, 2025
#############################################################################
#
#  Xinle 欣乐 — Master Infrastructure Setup Script & Bootstrapper
#
#  Single entry point for deploying the entire Xinle self-hosted
#  infrastructure stack on a fresh Ubuntu 24.04 LTS server.
#
#  Usage (single curl command — run as root):
#    curl -fsSL https://raw.githubusercontent.com/XinleSA/rmmx/main/scripts/01_master_setup.sh | sudo bash
#
#  What this script does (in order):
#    0.  Pre-flight root check & cleanup of previous failed installs
#    1.  Clone the repository from GitHub (bootstrap)
#    2.  Prompt user for all .env values (passwords, DB names, etc.)
#    3.  Write and validate the .env file
#    4.  Create the 'sar' service user and hand off execution
#    5.  Configure timezone (America/Chicago), NTP (us.pool.ntp.org), CIFS/NFS
#    6.  Install Docker CE + Docker Compose plugin
#    7.  Install and configure Grafana Alloy metrics agent
#    8.  Create /docker_apps directory structure with correct permissions
#    9.  Configure IPsec site-to-site VPN (strongSwan)
#   10.  Seed NetLock RMM configuration files
#   11.  Pull and start all Docker services
#   12.  Print deployment summary with VPN credentials
#
#  On ANY error:
#    - Full rollback is executed (all installed components removed)
#    - Full log is pushed to the GitHub repo under error_logs/
#    - Script exits with non-zero code
#############################################################################

set -euo pipefail

# =============================================================================
#  SELF-RE-EXEC GUARD — Must be the very first logic in the script
#  When invoked as "curl ... | sudo bash", bash's stdin IS the pipe (the
#  script itself). Any 'read' call will consume script bytes instead of
#  terminal input. Detect this and re-exec from a temp file so that
#  stdin is properly connected to the terminal (/dev/tty).
# =============================================================================
if [ ! -t 0 ]; then
    SELF_TMP="$(mktemp /tmp/xinle-setup-XXXXXX.sh)"
    # We are the pipe — slurp remaining stdin into temp file
    cat > "$SELF_TMP"
    chmod +x "$SELF_TMP"
    # Re-exec with stdin explicitly from /dev/tty
    exec bash "$SELF_TMP" "$@" < /dev/tty
fi

# ============================================================================
#  GLOBAL CONFIGURATION
# =============================================================================
readonly GITHUB_REPO="XinleSA/rmmx"
readonly GITHUB_RAW="https://raw.githubusercontent.com/${GITHUB_REPO}/main"
readonly PROJECT_DEST="/home/ubuntu/xinle-infra"
readonly DOCKER_APPS_DIR="/docker_apps"
readonly TARGET_USER="sar"
readonly PSK_FILE="/etc/ipsec.d/psk.txt"
readonly LOG_FILE="/tmp/xinle-install-$(date +%Y%m%d-%H%M%S).log"
readonly SCRIPT_START_TIME=$(date +%Y%m%d-%H%M%S)

# =============================================================================
#  STATE TRACKING FOR ROLLBACK
# =============================================================================
STATE_REPO_CLONED=false
STATE_ENV_WRITTEN=false
STATE_USER_CREATED=false
STATE_NTP_CONFIGURED=false
STATE_DOCKER_INSTALLED=false
STATE_ALLOY_INSTALLED=false
STATE_DOCKER_DIR_CREATED=false
STATE_IPSEC_INSTALLED=false
STATE_DOCKER_COMPOSE_UP=false

# =============================================================================
#  LOGGING — All output goes to terminal AND log file simultaneously
# =============================================================================
exec > >(tee -a "$LOG_FILE") 2>&1

# =============================================================================
#  HELPER FUNCTIONS
# =============================================================================
print_banner() {
    echo -e "\e[1;35m"
    echo "  ╔══════════════════════════════════════════════════════════════════╗"
    echo "  ║          Xinle 欣乐 — Infrastructure Deployment                 ║"
    echo "  ║          Author: James Barrett | Xinle, LLC                     ║"
    echo "  ║          Version: 12.3.0                                        ║"
    echo "  ╚══════════════════════════════════════════════════════════════════╝"
    echo -e "\e[0m"
}

print_header() {
    echo ""
    echo -e "\e[1;35m################################################################################\e[0m"
    echo -e "\e[1;35m  $1\e[0m"
    echo -e "\e[1;35m################################################################################\e[0m"
}

print_info()  { echo -e "\e[1;36m  [INFO]  $1\e[0m"; }
print_ok()    { echo -e "\e[1;32m  [OK]    $1\e[0m"; }
print_warn()  { echo -e "\e[1;33m  [WARN]  $1\e[0m"; }
print_error() { echo -e "\e[1;31m  [ERROR] $1\e[0m" >&2; }

prompt_required() {
    # prompt_required "Label" "variable_name" [default]
    # Reads from /dev/tty so it works even when stdin is a pipe (curl | bash)
    local label="$1"
    local varname="$2"
    local default="${3:-}"
    local value=""
    while [ -z "$value" ]; do
        if [ -n "$default" ]; then
            printf "  %s [%s]: " "$label" "$default" > /dev/tty
            read -r value < /dev/tty
            value="${value:-$default}"
        else
            printf "  %s: " "$label" > /dev/tty
            read -r value < /dev/tty
        fi
        if [ -z "$value" ]; then
            print_warn "This field is required. Please enter a value."
        fi
    done
    eval "$varname=\"$value\""
}

prompt_password() {
    # prompt_password "Label" "variable_name"
    # Reads from /dev/tty so it works even when stdin is a pipe (curl | bash).
    # Manually manages terminal echo so the password is hidden on screen.
    local label="$1"
    local varname="$2"
    local pass1="" pass2=""
    while true; do
        # Disable echo, read, restore echo
        printf "  %s: " "$label" > /dev/tty
        stty -echo < /dev/tty
        read -r pass1 < /dev/tty
        stty echo < /dev/tty
        printf "\n" > /dev/tty
        if [ -z "$pass1" ]; then
            print_warn "Password cannot be empty."
            continue
        fi
        printf "  Confirm %s: " "$label" > /dev/tty
        stty -echo < /dev/tty
        read -r pass2 < /dev/tty
        stty echo < /dev/tty
        printf "\n" > /dev/tty
        if [ "$pass1" = "$pass2" ]; then
            break
        else
            print_warn "Passwords do not match. Please try again."
        fi
    done
    eval "$varname=\"$pass1\""
}

# =============================================================================
#  PUSH ERROR LOG TO GITHUB
# =============================================================================
push_error_log() {
    print_header "Pushing Error Log to GitHub"

    local log_name="error_logs/install-failure-${SCRIPT_START_TIME}.log"
    local tmp_repo="/tmp/xinle-log-push-$$"

    # We need git configured to push — try to use the repo if it exists,
    # otherwise clone it fresh just for the log push
    local push_dir="$PROJECT_DEST"
    if [ ! -d "${push_dir}/.git" ]; then
        push_dir="$tmp_repo"
        if command -v git &>/dev/null; then
            git clone "https://github.com/${GITHUB_REPO}.git" "$push_dir" --depth=1 2>/dev/null || {
                print_warn "Could not clone repo for log push. Log is available locally at: $LOG_FILE"
                return 1
            }
        else
            print_warn "git not available. Log is available locally at: $LOG_FILE"
            return 1
        fi
    fi

    # Configure git identity for the push
    (
        cd "$push_dir"
        # Register as safe directory in case of uid mismatch (root vs ubuntu)
        git config --global --add safe.directory "$(pwd)" 2>/dev/null || true
        git config user.email "deploy@xinle.biz"
        git config user.name "Xinle Deploy Bot"
        mkdir -p error_logs

        # Sanitize log — strip passwords before pushing
        sed -E 's/(PASSWORD|PASSWD|password|passwd|PSK|psk)=[^ ]*/\1=<REDACTED>/g' \
            "$LOG_FILE" > "error_logs/install-failure-${SCRIPT_START_TIME}.log"

        git add "error_logs/"
        git commit -m "ci: install failure log ${SCRIPT_START_TIME}

Automatic error log from failed deployment on host: $(hostname)
Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
Log file: ${log_name}"

        if git push origin main 2>&1; then
            print_ok "Error log pushed to GitHub: ${log_name}"
        else
            print_warn "Could not push log to GitHub (may need auth). Log saved locally at: $LOG_FILE"
        fi
    ) || print_warn "Log push encountered an error. Log available at: $LOG_FILE"

    # Cleanup temp clone if used
    [ -d "$tmp_repo" ] && rm -rf "$tmp_repo" || true
}

# =============================================================================
#  ROLLBACK
# =============================================================================
rollback() {
    local exit_code=$?
    [ $exit_code -eq 0 ] && return

    print_header "ROLLBACK INITIATED — Error detected (exit code: ${exit_code})"
    print_info "Timestamp: $(date)"
    print_info "Undoing all installed components..."

    if [ "$STATE_DOCKER_COMPOSE_UP" = true ]; then
        print_info "Stopping and removing all Docker containers and volumes..."
        (cd "$PROJECT_DEST" && docker compose down -v --remove-orphans 2>/dev/null) || true
    fi

    if [ "$STATE_IPSEC_INSTALLED" = true ]; then
        print_info "Uninstalling IPsec (strongSwan)..."
        systemctl stop ipsec 2>/dev/null || true
        systemctl stop xfrm0-interface.service 2>/dev/null || true
        systemctl disable xfrm0-interface.service 2>/dev/null || true
        apt-get purge -y strongswan strongswan-starter 2>/dev/null || true
        rm -rf /etc/ipsec.conf /etc/ipsec.secrets /etc/ipsec.d || true
        rm -f /etc/systemd/system/xfrm0-interface.service || true
        ip link del xfrm0 2>/dev/null || true
        sed -i '/# Xinle xfrm0 FORWARD rules/,/^-A FORWARD -o xfrm0 -j ACCEPT/d' \
            /etc/ufw/before.rules 2>/dev/null || true
        systemctl daemon-reload 2>/dev/null || true
    fi

    if [ "$STATE_DOCKER_DIR_CREATED" = true ]; then
        print_info "Removing Docker application directory ${DOCKER_APPS_DIR}..."
        rm -rf "$DOCKER_APPS_DIR" || true
    fi

    if [ "$STATE_ALLOY_INSTALLED" = true ]; then
        print_info "Uninstalling Grafana Alloy..."
        systemctl stop alloy 2>/dev/null || true
        apt-get purge -y alloy 2>/dev/null || true
        rm -rf /etc/alloy /etc/apt/sources.list.d/grafana.list || true
    fi

    if [ "$STATE_DOCKER_INSTALLED" = true ]; then
        print_info "Uninstalling Docker..."
        apt-get --allow-remove-essential -y purge \
            docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
        rm -rf /var/lib/docker /etc/docker /etc/apt/sources.list.d/docker.list || true
    fi

    if [ "$STATE_NTP_CONFIGURED" = true ]; then
        print_info "Removing custom NTP configuration..."
        rm -f /etc/systemd/timesyncd.conf.d/xinle-ntp.conf || true
    fi

    if [ "$STATE_USER_CREATED" = true ]; then
        print_info "Deleting user '${TARGET_USER}'..."
        deluser --remove-home "$TARGET_USER" 2>/dev/null || true
    fi

    if [ "$STATE_ENV_WRITTEN" = true ]; then
        print_info "Removing .env file..."
        rm -f "${PROJECT_DEST}/.env" || true
    fi

    if [ "$STATE_REPO_CLONED" = true ]; then
        print_info "Removing cloned repository at ${PROJECT_DEST}..."
        rm -rf "$PROJECT_DEST" || true
    fi

    print_header "ROLLBACK COMPLETE — Pushing error log to GitHub..."
    push_error_log || true

    echo ""
    print_error "Installation failed and was fully rolled back."
    print_error "Log file: $LOG_FILE"
    echo ""
    exit $exit_code
}

trap rollback ERR

# =============================================================================
#  STAGE 0: PRE-FLIGHT ROOT CHECK
# =============================================================================
print_banner

if [ "${1:-}" != "--bootstrapped" ] && [ "${1:-}" != "--stage3" ]; then
    if [ "$(id -u)" -ne 0 ]; then
        print_error "This script must be run as root or with sudo."
        exit 1
    fi
fi

# =============================================================================
#  STAGE 1: BOOTSTRAP — Clone repo
# =============================================================================
if [ "${1:-}" != "--stage3" ]; then

    print_header "Stage 1: Bootstrap — Cloning Repository"

    if [ ! -d "$PROJECT_DEST/.git" ]; then
        print_info "Installing git if needed..."
        apt-get update -qq && apt-get install -y git curl

        print_info "Cloning ${GITHUB_REPO} to ${PROJECT_DEST}..."
        git clone "https://github.com/${GITHUB_REPO}.git" "$PROJECT_DEST"
        STATE_REPO_CLONED=true
        print_ok "Repository cloned."
    else
        print_info "Repository already exists. Pulling latest changes..."
        # Git 2.35.2+ rejects operations on repos owned by a different user.
        # Since this script runs as root (via sudo) but the repo may be owned
        # by the ubuntu user, we must register the directory as safe for root.
        git config --global --add safe.directory "$PROJECT_DEST" 2>/dev/null || true
        (cd "$PROJECT_DEST" && git pull origin main --rebase)
        print_ok "Repository up to date."
    fi

    # ==========================================================================
    #  STAGE 2: COLLECT ALL .ENV VALUES FROM USER
    # ==========================================================================
    print_header "Stage 2: Environment Configuration"
    echo ""
    echo -e "\e[1;33m  Please provide the following configuration values."
    echo -e "  These will be used to build your .env file.\e[0m"
    echo ""

    # --- PostgreSQL ---
    echo -e "\e[1;36m  ── PostgreSQL ──────────────────────────────────────────────────────────\e[0m"
    prompt_required "PostgreSQL database name"  ENV_POSTGRES_DB    "xinle_db"
    prompt_required "PostgreSQL username"        ENV_POSTGRES_USER  "sar"
    prompt_password "PostgreSQL password"        ENV_POSTGRES_PASSWORD

    # --- MySQL ---
    echo ""
    echo -e "\e[1;36m  ── MySQL ───────────────────────────────────────────────────────────────\e[0m"
    prompt_password "MySQL root password"         ENV_MYSQL_ROOT_PASSWORD
    prompt_password "MySQL application password"  ENV_MYSQL_PASSWORD

    # --- pgAdmin ---
    echo ""
    echo -e "\e[1;36m  ── pgAdmin ─────────────────────────────────────────────────────────────\e[0m"
    prompt_password "pgAdmin admin password"  ENV_PGADMIN_PASSWORD

    # --- Database names for apps ---
    echo ""
    echo -e "\e[1;36m  ── Application Databases ───────────────────────────────────────────────\e[0m"
    prompt_required "n8n database name"      ENV_N8N_DB      "n8n"
    prompt_required "Forgejo database name"  ENV_FORGEJO_DB  "forgejo"

    # --- Confirmation ---
    echo ""
    echo -e "\e[1;33m  ── Review Your Configuration ───────────────────────────────────────────\e[0m"
    echo ""
    echo "    POSTGRES_DB           = ${ENV_POSTGRES_DB}"
    echo "    POSTGRES_USER         = ${ENV_POSTGRES_USER}"
    echo "    POSTGRES_PASSWORD     = <hidden>"
    echo "    MYSQL_ROOT_PASSWORD   = <hidden>"
    echo "    MYSQL_PASSWORD        = <hidden>"
    echo "    PGADMIN_PASSWORD      = <hidden>"
    echo "    N8N_DB                = ${ENV_N8N_DB}"
    echo "    FORGEJO_DB            = ${ENV_FORGEJO_DB}"
    echo ""
    # Read confirmation from /dev/tty (stdin may be the pipe)
    printf "  Proceed with these settings? [Y/n]: " > /dev/tty
    read -r CONFIRM < /dev/tty
    CONFIRM="${CONFIRM:-Y}"
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        print_warn "Aborted by user. No changes were made."
        trap - ERR
        exit 0
    fi

    # --- Write .env ---
    print_info "Writing .env file to ${PROJECT_DEST}/.env ..."
    cat > "${PROJECT_DEST}/.env" << ENVEOF
# =============================================================================
#  Xinle 欣乐 — Runtime Environment Configuration
# =============================================================================
#  Author:        James Barrett | Company: Xinle, LLC
#  Generated:     $(date '+%Y-%m-%d %H:%M:%S %Z')
#  WARNING:       DO NOT COMMIT THIS FILE TO GIT
# =============================================================================

# --- PostgreSQL ---
POSTGRES_DB=${ENV_POSTGRES_DB}
POSTGRES_USER=${ENV_POSTGRES_USER}
POSTGRES_PASSWORD=${ENV_POSTGRES_PASSWORD}

# --- MySQL ---
MYSQL_ROOT_PASSWORD=${ENV_MYSQL_ROOT_PASSWORD}
MYSQL_PASSWORD=${ENV_MYSQL_PASSWORD}

# --- pgAdmin ---
PGADMIN_PASSWORD=${ENV_PGADMIN_PASSWORD}

# --- Application Databases ---
N8N_DB=${ENV_N8N_DB}
FORGEJO_DB=${ENV_FORGEJO_DB}
ENVEOF

    chmod 600 "${PROJECT_DEST}/.env"
    STATE_ENV_WRITTEN=true
    print_ok ".env written and secured (chmod 600)."

    # ==========================================================================
    #  STAGE 3: PRE-FLIGHT CLEANUP OF PREVIOUS FAILED INSTALLS
    # ==========================================================================
    print_header "Stage 3: Pre-flight Cleanup"
    print_info "Checking for traces of previous failed installations..."
    local_traces=false

    if id -u "$TARGET_USER" >/dev/null 2>&1; then
        print_warn "Found existing user '${TARGET_USER}'. Removing..."
        deluser --remove-home "$TARGET_USER" || true
        local_traces=true
    fi
    if [ -d "$DOCKER_APPS_DIR" ]; then
        print_warn "Found existing ${DOCKER_APPS_DIR}. Removing..."
        rm -rf "$DOCKER_APPS_DIR" || true
        local_traces=true
    fi
    if dpkg-query -W -f='${Status}' docker-ce 2>/dev/null | grep -q "install ok installed"; then
        print_warn "Found existing Docker installation. Purging..."
        apt-get --allow-remove-essential -y purge \
            docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin || true
        rm -rf /var/lib/docker /etc/docker || true
        local_traces=true
    fi

    if [ "$local_traces" = false ]; then
        print_ok "System is clean. No previous installation traces found."
    else
        print_ok "Pre-flight cleanup complete."
    fi

    # ==========================================================================
    #  STAGE 4: CREATE SERVICE USER & HAND OFF
    # ==========================================================================
    print_header "Stage 4: Service User Creation"

    if ! id -u "$TARGET_USER" >/dev/null 2>&1; then
        useradd -m -s /bin/bash -G sudo "$TARGET_USER"
        print_ok "User '${TARGET_USER}' created."
    else
        print_info "User '${TARGET_USER}' already exists."
    fi
    STATE_USER_CREATED=true

    getent group docker >/dev/null || groupadd docker
    usermod -aG docker "$TARGET_USER"
    chown -R "$TARGET_USER":"$TARGET_USER" "$PROJECT_DEST"

    print_info "Handing off execution to user '${TARGET_USER}'..."
    exec sudo -u "$TARGET_USER" -H \
        LOG_FILE="$LOG_FILE" \
        SCRIPT_START_TIME="$SCRIPT_START_TIME" \
        bash "${PROJECT_DEST}/scripts/01_master_setup.sh" --stage3
fi

# =============================================================================
#  STAGE 5+: MAIN INFRASTRUCTURE SETUP (runs as TARGET_USER)
# =============================================================================
if [ "$(whoami)" != "$TARGET_USER" ] && [ "${1:-}" = "--stage3" ]; then
    print_error "Stage 5+ must run as '${TARGET_USER}' but is running as '$(whoami)'. Aborting."
    exit 1
fi

print_header "Stage 5: Main Infrastructure Setup (as $(whoami))"
cd "$PROJECT_DEST"

# Re-source the .env now that we're running as TARGET_USER
if [ ! -f "${PROJECT_DEST}/.env" ]; then
    print_error ".env file missing at ${PROJECT_DEST}/.env — cannot continue."
    exit 1
fi
set -a
# shellcheck disable=SC1091
source "${PROJECT_DEST}/.env"
set +a
print_ok ".env loaded successfully."

# ---------------------------------------------------------------------------
#  Timezone, NTP, Share Support
# ---------------------------------------------------------------------------
print_header "Stage 5a: Timezone, NTP & Share Support"

sudo timedatectl set-timezone "America/Chicago"
sudo apt-get update -qq
sudo apt-get install -y cifs-utils nfs-common

sudo mkdir -p /etc/systemd/timesyncd.conf.d
cat << 'NTP_EOF' | sudo tee /etc/systemd/timesyncd.conf.d/xinle-ntp.conf > /dev/null
[Time]
NTP=us.pool.ntp.org
FallbackNTP=pool.ntp.org
NTP_EOF

sudo timedatectl set-ntp true
sudo systemctl restart systemd-timesyncd
STATE_NTP_CONFIGURED=true

print_ok "Timezone: America/Chicago | NTP: us.pool.ntp.org"
timedatectl status | grep -E "Time zone|NTP|synchronized"

# ---------------------------------------------------------------------------
#  Docker Installation
# ---------------------------------------------------------------------------
print_header "Stage 5b: Docker CE & Docker Compose Plugin"

if ! command -v docker &>/dev/null; then
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
    sudo apt-get install -y \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
fi

STATE_DOCKER_INSTALLED=true
print_ok "Docker $(docker --version) installed and running."

# ---------------------------------------------------------------------------
#  Grafana Alloy
# ---------------------------------------------------------------------------
print_header "Stage 5c: Grafana Alloy Metrics Agent"

sudo mkdir -p /etc/alloy
sudo cp "${PROJECT_DEST}/monitoring/alloy-config.alloy" /etc/alloy/config.alloy

if ! command -v alloy &>/dev/null; then
    sudo apt-get install -y wget gpg
    wget -qO- https://apt.grafana.com/gpg.key | \
        gpg --dearmor | sudo tee /usr/share/keyrings/grafana.gpg > /dev/null
    echo "deb [signed-by=/usr/share/keyrings/grafana.gpg] https://apt.grafana.com stable main" | \
        sudo tee /etc/apt/sources.list.d/grafana.list
    sudo apt-get update -qq
    sudo apt-get install -y alloy
fi

sudo chown -R alloy:alloy /etc/alloy
sudo systemctl enable --now alloy
STATE_ALLOY_INSTALLED=true
print_ok "Grafana Alloy installed and running."

# ---------------------------------------------------------------------------
#  Docker Application Directory
# ---------------------------------------------------------------------------
print_header "Stage 5d: Docker Application Directory Structure"

sudo mkdir -p \
    "${DOCKER_APPS_DIR}/npm/data" \
    "${DOCKER_APPS_DIR}/npm/letsencrypt" \
    "${DOCKER_APPS_DIR}/n8n" \
    "${DOCKER_APPS_DIR}/forgejo" \
    "${DOCKER_APPS_DIR}/postgres" \
    "${DOCKER_APPS_DIR}/pgadmin" \
    "${DOCKER_APPS_DIR}/mysql" \
    "${DOCKER_APPS_DIR}/netlockrmm/server/internal" \
    "${DOCKER_APPS_DIR}/netlockrmm/server/files" \
    "${DOCKER_APPS_DIR}/netlockrmm/server/logs" \
    "${DOCKER_APPS_DIR}/netlockrmm/web"

# pgAdmin requires UID 5050
sudo chown -R 5050:5050 "${DOCKER_APPS_DIR}/pgadmin"
sudo chown -R "$TARGET_USER":"$TARGET_USER" "$DOCKER_APPS_DIR"
sudo chown -R 5050:5050 "${DOCKER_APPS_DIR}/pgadmin"

STATE_DOCKER_DIR_CREATED=true
print_ok "Directory structure created under ${DOCKER_APPS_DIR}."

# ---------------------------------------------------------------------------
#  IPsec VPN
# ---------------------------------------------------------------------------
print_header "Stage 5e: IPsec Site-to-Site VPN (strongSwan)"

sudo chmod +x "${PROJECT_DEST}/scripts/05_setup_ipsec_vpn.sh"
sudo "${PROJECT_DEST}/scripts/05_setup_ipsec_vpn.sh"
STATE_IPSEC_INSTALLED=true

# ---------------------------------------------------------------------------
#  NetLock RMM Configuration Seeding
# ---------------------------------------------------------------------------
print_header "Stage 5f: NetLock RMM Configuration Seeding"

if [ ! -f "${DOCKER_APPS_DIR}/netlockrmm/server/appsettings.json" ]; then
    sed "s|\${MYSQL_PASSWORD}|${MYSQL_PASSWORD}|g" \
        "${PROJECT_DEST}/scripts/netlock-server-appsettings.json" | \
        sudo tee "${DOCKER_APPS_DIR}/netlockrmm/server/appsettings.json" > /dev/null
    print_ok "Seeded NetLock RMM server appsettings.json"
fi

if [ ! -f "${DOCKER_APPS_DIR}/netlockrmm/web/appsettings.json" ]; then
    sudo cp "${PROJECT_DEST}/scripts/netlock-web-appsettings.json" \
        "${DOCKER_APPS_DIR}/netlockrmm/web/appsettings.json"
    print_ok "Seeded NetLock RMM web console appsettings.json"
fi

sudo chown -R "$TARGET_USER":"$TARGET_USER" "${DOCKER_APPS_DIR}/netlockrmm"
print_ok "NetLock RMM configuration ready."

# ---------------------------------------------------------------------------
#  Pull & Start Docker Services
# ---------------------------------------------------------------------------
print_header "Stage 5g: Pulling Docker Images"
cd "$PROJECT_DEST"

while IFS= read -r service; do
    print_info "Pulling: ${service}..."
    sudo docker compose pull "$service" 2>&1 || \
        print_warn "Could not pull '${service}' — will use cached image if available."
done < <(sudo docker compose config --services)

print_header "Stage 5h: Starting All Docker Services"
sudo docker compose up -d
STATE_DOCKER_COMPOSE_UP=true
print_ok "All Docker services started."

# Brief wait then show container status
sleep 5
echo ""
sudo docker compose ps
echo ""

# ---------------------------------------------------------------------------
#  DEPLOYMENT SUMMARY
# ---------------------------------------------------------------------------
VPS_PUBLIC_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "<VPS_PUBLIC_IP>")
VPN_PSK=$(cat "${PSK_FILE}" 2>/dev/null || echo "<see /etc/ipsec.d/psk.txt>")

print_header "DEPLOYMENT COMPLETE ✓"
echo ""
echo -e "\e[1;32m  All services are running. Complete the following steps to finish setup:\e[0m"
echo ""
echo "  ┌─────────────────────────────────────────────────────────────────────┐"
echo "  │  STEP 1 — Cloudflare DNS                                            │"
echo "  │  Add A record: rmmx.xinle.biz → ${VPS_PUBLIC_IP}                   │"
echo "  │  Set proxy status to DNS Only (grey cloud) initially.               │"
echo "  ├─────────────────────────────────────────────────────────────────────┤"
echo "  │  STEP 2 — Nginx Proxy Manager Initial Login                         │"
echo "  │  URL:   http://${VPS_PUBLIC_IP}:81                                  │"
echo "  │  Login: admin@example.com / changeme                                │"
echo "  │  See:   docs/POST_INSTALL_RUNBOOK.md for full NPM configuration     │"
echo "  ├─────────────────────────────────────────────────────────────────────┤"
echo "  │  STEP 3 — UDM Pro Site-to-Site VPN                                  │"
echo "  │  (UniFi → Settings → Networks → Create Site-to-Site VPN)           │"
echo "  │                                                                     │"
echo "  │  Pre-Shared Key : ${VPN_PSK}                                        │"
echo "  │  VPS Address    : ${VPS_PUBLIC_IP}                                  │"
echo "  │  Remote Subnets : 172.20.0.0/16   (VPS Docker network)             │"
echo "  │  Local Subnets  : 10.1.0.0/24     (UDM Pro LAN)                   │"
echo "  │  IKE Version    : IKEv2 | AES-256 | SHA-256 | DH Group 14          │"
echo "  │  NOTE: UDM Pro must INITIATE. VPS listens.                         │"
echo "  │  Verify: sudo ipsec status && ping -c 3 10.1.0.1                   │"
echo "  │  Guide:  docs/07_ipsec_vpn_next_steps.md                           │"
echo "  └─────────────────────────────────────────────────────────────────────┘"
echo ""
echo "  Full runbook : ${PROJECT_DEST}/docs/POST_INSTALL_RUNBOOK.md"
echo "  Install log  : ${LOG_FILE}"
echo ""

# ---------------------------------------------------------------------------
#  Push success log to GitHub for records
# ---------------------------------------------------------------------------
print_header "Pushing Install Log to GitHub"
(
    cd "$PROJECT_DEST"
    # Register as safe directory in case of uid mismatch (root vs ubuntu)
    git config --global --add safe.directory "$PROJECT_DEST" 2>/dev/null || true
    git config user.email "deploy@xinle.biz"
    git config user.name "Xinle Deploy Bot"
    mkdir -p error_logs

    sed -E 's/(PASSWORD|PASSWD|password|passwd|PSK|psk|pre.shared.key)=[^ ]*/\1=<REDACTED>/gi' \
        "$LOG_FILE" > "error_logs/install-success-${SCRIPT_START_TIME}.log"

    git add error_logs/
    git commit -m "ci: successful install log ${SCRIPT_START_TIME}

Deployment completed successfully on host: $(hostname)
VPS IP: ${VPS_PUBLIC_IP}
Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC')" || true

    git push origin main 2>&1 && \
        print_ok "Install log pushed to GitHub: error_logs/install-success-${SCRIPT_START_TIME}.log" || \
        print_warn "Could not push success log. It is available locally at: $LOG_FILE"
) || true

trap - ERR
exit 0
