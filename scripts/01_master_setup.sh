#!/bin/bash
#############################################################################
# Author: James Barrett | Company: Xinle, LLC
# Version: 13.2.0
# Created: March 11, 2025
# Last Modified: March 11, 2025
#############################################################################
#
#  Xinle 欣乐 — Master Infrastructure Setup Script
#
#  DO NOT run this script directly via curl.
#  It must be invoked by bootstrap.sh which ensures:
#    - The repo is fully cloned/updated on disk before execution
#    - stdin is connected to the terminal (not a pipe)
#
#  Correct invocation (single command):
#    curl -fsSL https://raw.githubusercontent.com/XinleSA/rmmx/main/scripts/bootstrap.sh | sudo bash
#
#  What this script does:
#    1.  Prompt user for all .env values (passwords, DB names)
#    2.  Write and secure the .env file
#    3.  Pre-flight cleanup of previous failed installs
#    4.  Create the 'sar' service user
#    5.  Configure timezone (America/Chicago) + NTP (us.pool.ntp.org)
#    6.  Install Docker CE + Docker Compose plugin
#    7.  Install Grafana Alloy metrics agent
#    8.  Create /docker_apps directory structure
#    9.  Configure IPsec site-to-site VPN (strongSwan)
#   10.  Seed NetLock RMM configuration files
#   11.  Pull and start all Docker services
#   12.  Print deployment summary
#
#  On ANY error:
#    - Full rollback of all installed components
#    - Sanitized log pushed to GitHub under error_logs/
#############################################################################

set -euo pipefail

# =============================================================================
#  GLOBAL CONFIGURATION
# =============================================================================
readonly GITHUB_REPO="XinleSA/rmmx"
readonly PROJECT_DEST="/home/ubuntu/xinle-infra"
readonly DOCKER_APPS_DIR="/docker_apps"
readonly TARGET_USER="sar"
readonly PSK_FILE="/etc/ipsec.d/psk.txt"
readonly SCRIPT_START_TIME=$(date +%Y%m%d-%H%M%S)
readonly LOG_FILE="/tmp/xinle-install-${SCRIPT_START_TIME}.log"

# =============================================================================
#  STATE TRACKING FOR ROLLBACK
# =============================================================================
STATE_ENV_WRITTEN=false
STATE_USER_CREATED=false
STATE_NTP_CONFIGURED=false
STATE_DOCKER_INSTALLED=false
STATE_ALLOY_INSTALLED=false
STATE_DOCKER_DIR_CREATED=false
STATE_IPSEC_INSTALLED=false
STATE_DOCKER_COMPOSE_UP=false

# =============================================================================
#  LOGGING — tee all output to log file
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
    echo "  ║          Version: 13.2.0                                        ║"
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

wait_for_apt() {
    # Block until all apt/dpkg locks are released, then disable unattended-upgrades
    # for the duration of the install to prevent lock re-acquisition mid-run.
    local waited=0
    local max_wait=120  # seconds

    # Kill unattended-upgrades if running — it holds the lock for minutes
    if pgrep -x unattended-upgr >/dev/null 2>&1; then
        print_warn "unattended-upgrades is running. Stopping it for the install..."
        systemctl stop unattended-upgrades 2>/dev/null || true
        pkill -x unattended-upgr 2>/dev/null || true
        sleep 2
    fi

    # Also disable apt-daily timers during install
    systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
    systemctl stop apt-daily.service apt-daily-upgrade.service 2>/dev/null || true

    while fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock >/dev/null 2>&1; do
        if [ $waited -ge $max_wait ]; then
            print_error "apt lock held for ${max_wait}s — giving up. Run: sudo lsof /var/lib/dpkg/lock-frontend"
            return 1
        fi
        print_info "Waiting for apt lock... (${waited}s / ${max_wait}s)"
        sleep 5
        waited=$((waited + 5))
    done

    [ $waited -gt 0 ] && print_ok "apt lock released after ${waited}s."
    return 0
}

prompt_required() {
    local label="$1" varname="$2" default="${3:-}" value=""
    while [ -z "$value" ]; do
        if [ -n "$default" ]; then
            read -rp "  ${label} [${default}]: " value
            value="${value:-$default}"
        else
            read -rp "  ${label}: " value
        fi
        [ -z "$value" ] && print_warn "This field is required."
    done
    eval "${varname}=\"${value}\""
}

prompt_password() {
    local label="$1" varname="$2" pass1="" pass2=""
    while true; do
        read -rsp "  ${label}: " pass1; echo ""
        [ -z "$pass1" ] && { print_warn "Password cannot be empty."; continue; }
        read -rsp "  Confirm ${label}: " pass2; echo ""
        [ "$pass1" = "$pass2" ] && break
        print_warn "Passwords do not match. Please try again."
    done
    eval "${varname}=\"${pass1}\""
}

# =============================================================================
#  PUSH LOG TO GITHUB
# =============================================================================
push_log_to_github() {
    local label="$1"   # "failure" or "success"
    local logname="error_logs/install-${label}-${SCRIPT_START_TIME}.log"

    (
        cd "$PROJECT_DEST"
        git config --global --add safe.directory "$PROJECT_DEST" 2>/dev/null || true
        git config user.email "deploy@xinle.biz"
        git config user.name "Xinle Deploy Bot"

        # Set remote URL with embedded PAT so push never prompts for credentials.
        # The PAT is sourced from the existing remote URL set by bootstrap.sh,
        # or falls back to unauthenticated (public repo read — push will warn).
        local current_remote
        current_remote=$(git remote get-url origin 2>/dev/null || echo "")
        if [[ "$current_remote" != *"@github.com"* ]]; then
            # No PAT embedded yet — try to set one if GITHUB_PAT env var is set,
            # otherwise push will attempt anonymous (will fail on private repos)
            if [ -n "${GITHUB_PAT:-}" ]; then
                git remote set-url origin "https://${GITHUB_PAT}@github.com/${GITHUB_REPO}.git"
            fi
        fi

        mkdir -p error_logs

        # Sanitize — strip passwords/tokens before pushing
        sed -E 's/(PASSWORD|PASSWD|password|passwd|PSK|psk|TOKEN|token|PAT|ghp_[A-Za-z0-9]+)=[^[:space:]]*/\1=<REDACTED>/g' \
            "$LOG_FILE" > "$logname"

        git add error_logs/
        git commit -m "ci: install ${label} log ${SCRIPT_START_TIME}

Host: $(hostname) | IP: $(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo unknown)
Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC')" 2>/dev/null || true

        GIT_TERMINAL_PROMPT=0 git push origin main 2>&1 && \
            print_ok "Log pushed → GitHub: ${logname}" || \
            print_warn "Log push skipped (no auth). Log available locally: ${LOG_FILE}"
    ) || print_warn "Log push encountered an error. Log at: ${LOG_FILE}"
}

# =============================================================================
#  ROLLBACK
# =============================================================================
rollback() {
    local exit_code=$?
    [ $exit_code -eq 0 ] && return

    print_header "ROLLBACK INITIATED (exit code: ${exit_code}) — $(date)"

    [ "$STATE_DOCKER_COMPOSE_UP"  = true ] && {
        print_info "Stopping Docker containers..."
        (cd "$PROJECT_DEST" && docker compose down -v --remove-orphans 2>/dev/null) || true
    }
    [ "$STATE_IPSEC_INSTALLED"    = true ] && {
        print_info "Removing strongSwan IPsec..."
        systemctl stop ipsec xfrm0-interface.service 2>/dev/null || true
        systemctl disable xfrm0-interface.service 2>/dev/null || true
        apt-get purge -y strongswan strongswan-starter 2>/dev/null || true
        rm -rf /etc/ipsec.conf /etc/ipsec.secrets /etc/ipsec.d
        rm -f /etc/systemd/system/xfrm0-interface.service
        ip link del xfrm0 2>/dev/null || true
        sed -i '/# Xinle xfrm0 FORWARD rules/,/^-A FORWARD -o xfrm0 -j ACCEPT/d' \
            /etc/ufw/before.rules 2>/dev/null || true
        systemctl daemon-reload 2>/dev/null || true
    }
    [ "$STATE_DOCKER_DIR_CREATED" = true ] && {
        print_info "Removing ${DOCKER_APPS_DIR}..."
        rm -rf "$DOCKER_APPS_DIR" || true
    }
    [ "$STATE_ALLOY_INSTALLED"    = true ] && {
        print_info "Removing Grafana Alloy..."
        systemctl stop alloy 2>/dev/null || true
        apt-get purge -y alloy 2>/dev/null || true
        rm -rf /etc/alloy /etc/apt/sources.list.d/grafana.list || true
    }
    [ "$STATE_DOCKER_INSTALLED"   = true ] && {
        print_info "Removing Docker..."
        apt-get --allow-remove-essential -y purge \
            docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
        rm -rf /var/lib/docker /etc/docker /etc/apt/sources.list.d/docker.list || true
    }
    [ "$STATE_NTP_CONFIGURED"     = true ] && {
        print_info "Removing custom NTP config..."
        rm -f /etc/systemd/timesyncd.conf.d/xinle-ntp.conf || true
        # Also clean up chrony if it was installed as fallback
        apt-get purge -y chrony 2>/dev/null || true
        sed -i 's/^#pool/pool/g; s/^#server/server/g' /etc/chrony/chrony.conf 2>/dev/null || true
    }
    [ "$STATE_USER_CREATED"       = true ] && {
        print_info "Removing user '${TARGET_USER}'..."
        deluser --remove-home "$TARGET_USER" 2>/dev/null || true
    }
    [ "$STATE_ENV_WRITTEN"        = true ] && {
        print_info "Removing .env..."
        rm -f "${PROJECT_DEST}/.env" || true
    }

    # Re-enable apt timers regardless of rollback state
    systemctl start apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true

    print_header "ROLLBACK COMPLETE — Pushing error log to GitHub"
    push_log_to_github "failure" || true

    echo ""
    print_error "Installation failed and was fully rolled back."
    print_error "Log: ${LOG_FILE}"
    exit $exit_code
}

trap rollback ERR

# =============================================================================
#  ROOT CHECK
# =============================================================================
print_banner

if [ "$(id -u)" -ne 0 ]; then
    print_error "Must be run as root or with sudo."
    exit 1
fi

# =============================================================================
#  STAGE 1: COLLECT .ENV VALUES
# =============================================================================
print_header "Stage 1: Environment Configuration"
echo ""
echo -e "\e[1;33m  Enter the following values to configure your deployment.\e[0m"
echo -e "\e[1;33m  Passwords are hidden as you type and must be confirmed.\e[0m"
echo ""

echo -e "\e[1;36m  ── PostgreSQL ──────────────────────────────────────────────────────────\e[0m"
prompt_required "PostgreSQL database name"  ENV_POSTGRES_DB   "xinle_db"
prompt_required "PostgreSQL username"       ENV_POSTGRES_USER "sar"
prompt_password "PostgreSQL password"       ENV_POSTGRES_PASSWORD

echo ""
echo -e "\e[1;36m  ── MySQL ───────────────────────────────────────────────────────────────\e[0m"
prompt_password "MySQL root password"        ENV_MYSQL_ROOT_PASSWORD
prompt_password "MySQL app user password"    ENV_MYSQL_PASSWORD

echo ""
echo -e "\e[1;36m  ── pgAdmin ─────────────────────────────────────────────────────────────\e[0m"
prompt_password "pgAdmin admin password"     ENV_PGADMIN_PASSWORD

echo ""
echo -e "\e[1;36m  ── Application Database Names ──────────────────────────────────────────\e[0m"
prompt_required "n8n database name"     ENV_N8N_DB     "n8n"
prompt_required "Forgejo database name" ENV_FORGEJO_DB "forgejo"

# --- Confirmation ---
echo ""
echo -e "\e[1;33m  ── Review ──────────────────────────────────────────────────────────────\e[0m"
echo ""
printf "    %-30s %s\n" "POSTGRES_DB:"          "$ENV_POSTGRES_DB"
printf "    %-30s %s\n" "POSTGRES_USER:"        "$ENV_POSTGRES_USER"
printf "    %-30s %s\n" "POSTGRES_PASSWORD:"    "<hidden>"
printf "    %-30s %s\n" "MYSQL_ROOT_PASSWORD:"  "<hidden>"
printf "    %-30s %s\n" "MYSQL_PASSWORD:"       "<hidden>"
printf "    %-30s %s\n" "PGADMIN_PASSWORD:"     "<hidden>"
printf "    %-30s %s\n" "N8N_DB:"               "$ENV_N8N_DB"
printf "    %-30s %s\n" "FORGEJO_DB:"           "$ENV_FORGEJO_DB"
echo ""
read -rp "  Proceed with these settings? [Y/n]: " CONFIRM
CONFIRM="${CONFIRM:-Y}"
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    print_warn "Aborted by user. No changes made."
    trap - ERR
    exit 0
fi

# --- Write .env ---
print_info "Writing .env ..."
cat > "${PROJECT_DEST}/.env" << ENVEOF
# =============================================================================
#  Xinle 欣乐 — Runtime Environment Configuration
#  Author: James Barrett | Company: Xinle, LLC
#  Generated: $(date '+%Y-%m-%d %H:%M:%S %Z')
#  WARNING: DO NOT COMMIT THIS FILE TO GIT
# =============================================================================

POSTGRES_DB=${ENV_POSTGRES_DB}
POSTGRES_USER=${ENV_POSTGRES_USER}
POSTGRES_PASSWORD=${ENV_POSTGRES_PASSWORD}

MYSQL_ROOT_PASSWORD=${ENV_MYSQL_ROOT_PASSWORD}
MYSQL_PASSWORD=${ENV_MYSQL_PASSWORD}

PGADMIN_PASSWORD=${ENV_PGADMIN_PASSWORD}

N8N_DB=${ENV_N8N_DB}
FORGEJO_DB=${ENV_FORGEJO_DB}
ENVEOF

chmod 600 "${PROJECT_DEST}/.env"
STATE_ENV_WRITTEN=true
print_ok ".env written and secured (chmod 600)."

# =============================================================================
#  STAGE 2: PRE-FLIGHT CLEANUP
# =============================================================================
print_header "Stage 2: Pre-flight Cleanup"

traces=false
id -u "$TARGET_USER" >/dev/null 2>&1 && {
    print_warn "Removing existing user '${TARGET_USER}'..."
    deluser --remove-home "$TARGET_USER" || true; traces=true; }
[ -d "$DOCKER_APPS_DIR" ] && {
    print_warn "Removing existing ${DOCKER_APPS_DIR}..."
    rm -rf "$DOCKER_APPS_DIR" || true; traces=true; }
dpkg-query -W -f='${Status}' docker-ce 2>/dev/null | grep -q "install ok installed" && {
    print_warn "Removing existing Docker installation..."
    apt-get --allow-remove-essential -y purge \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
    rm -rf /var/lib/docker /etc/docker || true; traces=true; }

[ "$traces" = false ] && print_ok "System is clean." || print_ok "Pre-flight cleanup complete."

# =============================================================================
#  STAGE 3: SERVICE USER
# =============================================================================
print_header "Stage 3: Service User '${TARGET_USER}'"

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
print_ok "User configured."

# =============================================================================
#  STAGE 4: TIMEZONE & NTP
# =============================================================================
print_header "Stage 4: Timezone & NTP"

timedatectl set-timezone "America/Chicago" || true
wait_for_apt
apt-get update -qq
apt-get install -y cifs-utils nfs-common

# Determine NTP method — timedatectl set-ntp is blocked on many VPS/container
# environments (returns "NTP not supported"). Fall back to chrony which works
# universally including inside OpenVZ, LXC, and restricted KVM VMs.
NTP_METHOD="none"

if timedatectl set-ntp true 2>/dev/null; then
    # systemd-timesyncd is available and allowed
    mkdir -p /etc/systemd/timesyncd.conf.d
    cat > /etc/systemd/timesyncd.conf.d/xinle-ntp.conf << 'NTP_EOF'
[Time]
NTP=us.pool.ntp.org
FallbackNTP=pool.ntp.org
NTP_EOF
    systemctl restart systemd-timesyncd 2>/dev/null || true
    NTP_METHOD="systemd-timesyncd"
else
    # Fall back to chrony — works in all VPS/container environments
    print_warn "systemd-timesyncd NTP not supported on this host. Installing chrony..."
    wait_for_apt
    apt-get install -y chrony
    # Configure chrony to use us.pool.ntp.org
    if grep -q "^pool\|^server" /etc/chrony/chrony.conf 2>/dev/null; then
        # Comment out existing pool/server lines and add ours
        sed -i 's/^pool/#pool/g; s/^server/#server/g' /etc/chrony/chrony.conf
    fi
    grep -q "us.pool.ntp.org" /etc/chrony/chrony.conf 2>/dev/null ||         echo "pool us.pool.ntp.org iburst" >> /etc/chrony/chrony.conf
    systemctl enable --now chrony 2>/dev/null ||         systemctl enable --now chronyd 2>/dev/null || true
    NTP_METHOD="chrony"
fi

STATE_NTP_CONFIGURED=true
print_ok "Timezone: America/Chicago | NTP: us.pool.ntp.org (via ${NTP_METHOD})"
timedatectl status | grep -E "Time zone|NTP|synchronized|time" | head -5 || true

# =============================================================================
#  STAGE 5: DOCKER
# =============================================================================
print_header "Stage 5: Docker CE & Compose Plugin"

if ! command -v docker &>/dev/null; then
    wait_for_apt
    apt-get install -y ca-certificates curl
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
      https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null
    wait_for_apt
    apt-get update -qq
    apt-get install -y \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
fi
STATE_DOCKER_INSTALLED=true
print_ok "Docker $(docker --version) ready."

# =============================================================================
#  STAGE 6: GRAFANA ALLOY
# =============================================================================
print_header "Stage 6: Grafana Alloy"

mkdir -p /etc/alloy
cp "${PROJECT_DEST}/monitoring/alloy-config.alloy" /etc/alloy/config.alloy

if ! command -v alloy &>/dev/null; then
    wait_for_apt
    apt-get install -y wget gpg
    wget -qO- https://apt.grafana.com/gpg.key | \
        gpg --dearmor | tee /usr/share/keyrings/grafana.gpg > /dev/null
    echo "deb [signed-by=/usr/share/keyrings/grafana.gpg] https://apt.grafana.com stable main" | \
        tee /etc/apt/sources.list.d/grafana.list
    wait_for_apt
    apt-get update -qq
    apt-get install -y alloy
fi
chown -R alloy:alloy /etc/alloy
systemctl enable --now alloy
STATE_ALLOY_INSTALLED=true
print_ok "Grafana Alloy installed."

# =============================================================================
#  STAGE 7: DOCKER APP DIRECTORY STRUCTURE
# =============================================================================
print_header "Stage 7: /docker_apps Directory Structure"

mkdir -p \
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

chown -R "$TARGET_USER":"$TARGET_USER" "$DOCKER_APPS_DIR"
chown -R 5050:5050 "${DOCKER_APPS_DIR}/pgadmin"
STATE_DOCKER_DIR_CREATED=true
print_ok "Directory structure created."

# =============================================================================
#  STAGE 8: IPSEC VPN
# =============================================================================
print_header "Stage 8: IPsec Site-to-Site VPN"

chmod +x "${PROJECT_DEST}/scripts/05_setup_ipsec_vpn.sh"
bash "${PROJECT_DEST}/scripts/05_setup_ipsec_vpn.sh"
STATE_IPSEC_INSTALLED=true

# =============================================================================
#  STAGE 9: NETLOCK RMM CONFIG SEEDING
# =============================================================================
print_header "Stage 9: NetLock RMM Configuration"

# Source .env so we have MYSQL_PASSWORD available
set -a; source "${PROJECT_DEST}/.env"; set +a

[ ! -f "${DOCKER_APPS_DIR}/netlockrmm/server/appsettings.json" ] && {
    sed "s|\${MYSQL_PASSWORD}|${MYSQL_PASSWORD}|g" \
        "${PROJECT_DEST}/scripts/netlock-server-appsettings.json" \
        > "${DOCKER_APPS_DIR}/netlockrmm/server/appsettings.json"
    print_ok "Seeded netlockrmm-server appsettings.json"
}
[ ! -f "${DOCKER_APPS_DIR}/netlockrmm/web/appsettings.json" ] && {
    cp "${PROJECT_DEST}/scripts/netlock-web-appsettings.json" \
        "${DOCKER_APPS_DIR}/netlockrmm/web/appsettings.json"
    print_ok "Seeded netlockrmm-web appsettings.json"
}
chown -R "$TARGET_USER":"$TARGET_USER" "${DOCKER_APPS_DIR}/netlockrmm"

# =============================================================================
#  STAGE 10: PULL & START DOCKER SERVICES
# =============================================================================
print_header "Stage 10: Pulling Docker Images"
cd "$PROJECT_DEST"

while IFS= read -r svc; do
    print_info "Pulling: ${svc}..."
    docker compose pull "$svc" 2>&1 || \
        print_warn "Could not pull '${svc}' — will use cached image if available."
done < <(docker compose config --services)

print_header "Stage 11: Starting All Docker Services"
docker compose up -d
STATE_DOCKER_COMPOSE_UP=true
print_ok "All services started."

sleep 5
echo ""
docker compose ps
echo ""

# Re-enable apt-daily timers now that install is complete
systemctl start apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true

# =============================================================================
#  DEPLOYMENT SUMMARY
# =============================================================================
VPS_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "<VPS_IP>")
VPN_PSK=$(cat "${PSK_FILE}" 2>/dev/null || echo "<see /etc/ipsec.d/psk.txt>")

print_header "DEPLOYMENT COMPLETE ✓"
echo ""
echo -e "\e[1;32m  All services are running. Complete these steps to finish:\e[0m"
echo ""
echo "  ┌─────────────────────────────────────────────────────────────────────┐"
echo "  │  STEP 1 — Cloudflare DNS                                            │"
echo "  │  A record: rmmx.xinle.biz → ${VPS_IP}                              │"
echo "  │  Proxy: DNS Only (grey cloud) initially                             │"
echo "  ├─────────────────────────────────────────────────────────────────────┤"
echo "  │  STEP 2 — Nginx Proxy Manager                                       │"
echo "  │  URL:   http://${VPS_IP}:81                                         │"
echo "  │  Login: admin@example.com / changeme                                │"
echo "  ├─────────────────────────────────────────────────────────────────────┤"
echo "  │  STEP 3 — UDM Pro IPsec VPN                                         │"
echo "  │  PSK     : ${VPN_PSK}                                               │"
echo "  │  VPS IP  : ${VPS_IP}                                                │"
echo "  │  Remote  : 172.20.0.0/16  |  Local: 10.1.0.0/24                    │"
echo "  │  IKEv2 | AES-256 | SHA-256 | DH Group 14                           │"
echo "  │  Guide: docs/07_ipsec_vpn_next_steps.md                            │"
echo "  └─────────────────────────────────────────────────────────────────────┘"
echo ""
echo "  Runbook : ${PROJECT_DEST}/docs/POST_INSTALL_RUNBOOK.md"
echo "  Log     : ${LOG_FILE}"
echo ""

print_header "Pushing install log to GitHub"
push_log_to_github "success" || true

trap - ERR
exit 0
