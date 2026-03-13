#!/bin/bash
#############################################################################
# Author: James Barrett | Company: Xinle, LLC
# Version: 13.23.0
# Created: March 11, 2025
# Last Modified: March 13, 2026
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
#  STDIN / TTY GUARD
# =============================================================================
# This script requires an interactive terminal (TTY) for password prompts.
# If it is being piped from curl (stdin is a pipe, not a TTY), redirect the
# user to bootstrap.sh which correctly handles the TTY hand-off.
if [ ! -t 0 ]; then
    echo ""
    echo -e "\e[1;31m  [ERROR] This script must NOT be run directly via curl pipe.\e[0m"
    echo -e "\e[1;31m          stdin is not a terminal — password prompts will fail.\e[0m"
    echo ""
    echo -e "\e[1;33m  Use the correct bootstrap command instead:\e[0m"
    echo ""
    echo -e "\e[1;36m    curl -fsSL https://raw.githubusercontent.com/XinleSA/rmmx/main/scripts/bootstrap.sh | sudo bash\e[0m"
    echo ""
    exit 1
fi

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
    echo "  ║          Version: 13.21.0                                       ║"
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

disable_needrestart() {
    # needrestart is a dpkg trigger that runs after every apt install.
    # It checks if services need restarting and prompts interactively,
    # hanging forever when stdin is not a terminal (e.g. piped scripts).
    # NEEDRESTART_MODE=a tells it to restart services automatically without
    # prompting. We also write a config drop-in so it stays silent for the
    # full duration of this script. Both are cleaned up on exit.
    export NEEDRESTART_MODE=a
    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_SUSPEND=1

    if [ -d /etc/needrestart/conf.d ]; then
        cat > /etc/needrestart/conf.d/99-xinle-install.conf << 'NREOF'
# Xinle install: suppress interactive prompts during automated install
$nrconf{restart} = 'a';
$nrconf{kernelhints} = 0;
$nreof{ucodehints} = 0;
NREOF
        print_info "needrestart set to automatic mode for install duration."
    fi

    # Kill any needrestart already running (from a previous apt call)
    pkill -KILL -f needrestart 2>/dev/null || true
}

restore_needrestart() {
    rm -f /etc/needrestart/conf.d/99-xinle-install.conf 2>/dev/null || true
    unset NEEDRESTART_MODE NEEDRESTART_SUSPEND 2>/dev/null || true
}

force_wipe_docker_data() {
    # MySQL and PostgreSQL write data as root into bind-mounted host dirs.
    # A simple rm -rf /docker_apps often fails with "Directory not empty"
    # because the files are owned by the container's internal UID (999 for
    # mysql, 70 for postgres) which differs from the host root user context.
    # Solution: run a temporary alpine container as root to wipe the data,
    # which has permission to delete files regardless of ownership.
    local target="${1:-/docker_apps}"
    if [ -d "$target" ]; then
        print_info "Force-wiping ${target} via Docker (handles root-owned container data)..."
        docker run --rm -v "${target}:/wipe" alpine             sh -c "rm -rf /wipe/* /wipe/.[!.]* 2>/dev/null; echo done" 2>/dev/null || true
        rm -rf "$target" 2>/dev/null || true
        print_info "${target} wiped."
    fi
}

wait_for_apt() {
    # Ensures apt/dpkg is fully available before running any apt-get command.
    # Strategy (escalating):
    #   1. Stop all known lock-holders (unattended-upgrades, apt-daily)
    #   2. Wait up to 30s for clean release
    #   3. If still locked: kill ALL apt/dpkg processes and remove lock files
    #      (safe on a fresh VPS mid-install — no partial transactions in flight)
    #   4. Run dpkg --configure -a to clean up any interrupted state
    local waited=0
    local soft_wait=30   # seconds to wait politely before going nuclear
    local lock_files=(
        /var/lib/dpkg/lock-frontend
        /var/lib/dpkg/lock
        /var/cache/apt/archives/lock
        /var/lib/apt/lists/lock
    )

    # --- Step 1: Stop all known apt background services ---
    print_info "Ensuring apt is free..."
    systemctl stop unattended-upgrades apt-daily.service         apt-daily-upgrade.service 2>/dev/null || true
    systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true

    # Kill any lingering unattended-upgrades or apt processes gracefully
    pkill -TERM -f unattended-upgrade 2>/dev/null || true
    pkill -TERM -f "apt-get"          2>/dev/null || true
    pkill -TERM -f "dpkg"             2>/dev/null || true
    sleep 3

    # --- Step 2: Wait politely up to soft_wait seconds ---
    while fuser "${lock_files[@]}" >/dev/null 2>&1; do
        if [ $waited -ge $soft_wait ]; then
            break  # escalate to nuclear
        fi
        print_info "Waiting for apt lock... (${waited}s)"
        sleep 5
        waited=$((waited + 5))
    done

    # --- Step 3: Nuclear option — forcibly remove lock files ---
    if fuser "${lock_files[@]}" >/dev/null 2>&1; then
        print_warn "apt lock still held after ${waited}s. Forcibly clearing..."

        # Kill any remaining apt/dpkg processes hard
        pkill -KILL -f unattended-upgrade 2>/dev/null || true
        pkill -KILL -f "apt-get"          2>/dev/null || true
        pkill -KILL -f "dpkg"             2>/dev/null || true
        sleep 2

        # Remove the lock files — safe because we killed all holders
        for lf in "${lock_files[@]}"; do
            [ -f "$lf" ] && rm -f "$lf" &&                 print_info "Removed stale lock: $lf" || true
        done

        # Remove any dpkg front-end lock socket
        rm -f /var/lib/dpkg/lock-frontend 2>/dev/null || true
    fi

    # --- Step 4: Repair any interrupted dpkg state ---
    print_info "Running dpkg --configure -a to repair any interrupted state..."
    DEBIAN_FRONTEND=noninteractive dpkg --configure -a 2>/dev/null || true

    print_ok "apt is ready."
    return 0
}

prompt_required() {
    local label="$1" varname="$2" default="${3:-}" value=""
    while [ -z "$value" ]; do
        if [ -n "$default" ]; then
            read -rp "  ${label} [${default}]: " value </dev/tty
            value="${value:-$default}"
        else
            read -rp "  ${label}: " value </dev/tty
        fi
        [ -z "$value" ] && print_warn "This field is required."
    done
    eval "${varname}=\"${value}\""
}

prompt_password() {
    local label="$1" varname="$2" pass1="" pass2=""
    while true; do
        read -rsp "  ${label}: " pass1 </dev/tty; echo ""
        [ -z "$pass1" ] && { print_warn "Password cannot be empty."; continue; }
        read -rsp "  Confirm ${label}: " pass2 </dev/tty; echo ""
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

        # Always set the authenticated remote URL using the embedded PAT.
        # GITHUB_PAT is exported by bootstrap.sh before handing off to this script.
        # GIT_TERMINAL_PROMPT=0 and GIT_ASKPASS=true prevent any credential prompts
        # (git would otherwise try to read from /dev/tty which fails in some envs).
        if [ -n "${GITHUB_PAT:-}" ]; then
            git remote set-url origin "https://${GITHUB_PAT}@github.com/${GITHUB_REPO}.git"
        fi

        mkdir -p error_logs

        # Sanitize — strip passwords/tokens before pushing
        sed -E 's/(PASSWORD|PASSWD|password|passwd|PSK|psk|TOKEN|token|PAT|ghp_[A-Za-z0-9]+)=[^[:space:]]*/\1=<REDACTED>/g' \
            "$LOG_FILE" > "$logname"

        git add error_logs/
        git commit -m "ci: install ${label} log ${SCRIPT_START_TIME}

Host: $(hostname) | IP: $(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo unknown)
Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC')" 2>/dev/null || true

        # Push HEAD to main. GIT_ASKPASS=true returns empty string for any prompt,
        # effectively disabling interactive credential requests without failing.
        GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=true git push origin HEAD:main 2>&1 && \
            print_ok "Log pushed → GitHub: ${logname}" || \
            print_warn "Log push skipped. Log available locally: ${LOG_FILE}"
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
        systemctl stop ipsec xfrm0-interface.service xinle-firewall.service 2>/dev/null || true
        systemctl disable xfrm0-interface.service xinle-firewall.service 2>/dev/null || true
        apt-get purge -y strongswan strongswan-starter 2>/dev/null || true
        rm -rf /etc/ipsec.conf /etc/ipsec.secrets /etc/ipsec.d
        rm -f /etc/systemd/system/xfrm0-interface.service
        rm -f /etc/systemd/system/xinle-firewall.service
        ip link del xfrm0 2>/dev/null || true
        systemctl daemon-reload 2>/dev/null || true
    }
    [ "$STATE_DOCKER_DIR_CREATED" = true ] && {
        print_info "Removing ${DOCKER_APPS_DIR}..."
        (cd "$PROJECT_DEST" && docker compose down -v --remove-orphans 2>/dev/null) || true
        force_wipe_docker_data "$DOCKER_APPS_DIR"
    }
    [ "$STATE_ALLOY_INSTALLED"    = true ] && {
        print_info "Removing Grafana Alloy..."
        systemctl stop alloy 2>/dev/null || true
        apt-get purge -y alloy 2>/dev/null || true
        rm -rf /etc/alloy /etc/apt/sources.list.d/grafana.list                /usr/share/keyrings/grafana.gpg || true
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
    restore_needrestart

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

# Suppress needrestart interactive prompts for the entire install
disable_needrestart

# =============================================================================
#  STAGE 1: COLLECT .ENV VALUES
# =============================================================================
print_header "Stage 1: Environment Configuration"
echo ""
echo -e "\e[1;33m  Enter the following values to configure your deployment.\e[0m"
echo -e "\e[1;33m  Passwords are hidden as you type and must be confirmed.\e[0m"
echo ""

# ---------------------------------------------------------------------------
#  Password strategy — ask once or individually
# ---------------------------------------------------------------------------
echo -e "\e[1;36m  ── Password Strategy ───────────────────────────────────────────────────\e[0m"
echo ""
echo "  You can use a single shared password for all services (quick setup),"
echo "  or set a unique password for each service (recommended for production)."
echo ""
read -rp "  Use the same password for all services? [Y/n]: " PW_SAME </dev/tty
PW_SAME="${PW_SAME:-Y}"
echo ""

SHARED_PASSWORD=""
if [[ "$PW_SAME" =~ ^[Yy]$ ]]; then
    print_info "Enter one password — it will be used for all services."
    echo ""
    prompt_password "Shared password (all services)" SHARED_PASSWORD
    ENV_POSTGRES_PASSWORD="$SHARED_PASSWORD"
    ENV_MYSQL_ROOT_PASSWORD="$SHARED_PASSWORD"
    ENV_MYSQL_PASSWORD="$SHARED_PASSWORD"
    ENV_PGADMIN_PASSWORD="$SHARED_PASSWORD"
    print_ok "Single password set for all services."
else
    print_info "Enter individual passwords for each service."
    echo ""
    echo -e "\e[1;36m  ── PostgreSQL ──────────────────────────────────────────────────────────\e[0m"
    prompt_password "PostgreSQL password"        ENV_POSTGRES_PASSWORD
    echo ""
    echo -e "\e[1;36m  ── MySQL ───────────────────────────────────────────────────────────────\e[0m"
    prompt_password "MySQL root password"        ENV_MYSQL_ROOT_PASSWORD
    prompt_password "MySQL app user password"    ENV_MYSQL_PASSWORD
    echo ""
    echo -e "\e[1;36m  ── pgAdmin ─────────────────────────────────────────────────────────────\e[0m"
    prompt_password "pgAdmin admin password"     ENV_PGADMIN_PASSWORD
fi

# ---------------------------------------------------------------------------
#  Non-password configuration
# ---------------------------------------------------------------------------
echo ""
echo -e "\e[1;36m  ── PostgreSQL ──────────────────────────────────────────────────────────\e[0m"
prompt_required "PostgreSQL database name"  ENV_POSTGRES_DB   "xinle_db"
prompt_required "PostgreSQL username"       ENV_POSTGRES_USER "sar"

echo ""
echo -e "\e[1;36m  ── Application Database Names ──────────────────────────────────────────\e[0m"
prompt_required "n8n database name"     ENV_N8N_DB     "n8n"
prompt_required "Forgejo database name" ENV_FORGEJO_DB "forgejo"

# --- Confirmation ---
echo ""
echo -e "\e[1;33m  ── Review ──────────────────────────────────────────────────────────────\e[0m"
echo ""
printf "    %-30s %s\n" "POSTGRES_DB:"         "$ENV_POSTGRES_DB"
printf "    %-30s %s\n" "POSTGRES_USER:"       "$ENV_POSTGRES_USER"
if [[ "$PW_SAME" =~ ^[Yy]$ ]]; then
    printf "    %-30s %s\n" "ALL PASSWORDS:"   "<single shared password>"
else
    printf "    %-30s %s\n" "POSTGRES_PASSWORD:"   "<hidden>"
    printf "    %-30s %s\n" "MYSQL_ROOT_PASSWORD:" "<hidden>"
    printf "    %-30s %s\n" "MYSQL_PASSWORD:"      "<hidden>"
    printf "    %-30s %s\n" "PGADMIN_PASSWORD:"    "<hidden>"
fi
printf "    %-30s %s\n" "N8N_DB:"              "$ENV_N8N_DB"
printf "    %-30s %s\n" "FORGEJO_DB:"          "$ENV_FORGEJO_DB"
echo ""
read -rp "  Proceed with these settings? [Y/n]: " CONFIRM </dev/tty
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
    print_warn "Removing existing ${DOCKER_APPS_DIR} (including any MySQL/postgres data)..."
    docker compose -f "${PROJECT_DEST}/docker-compose.yml" down -v         --remove-orphans 2>/dev/null || true
    force_wipe_docker_data "$DOCKER_APPS_DIR"
    traces=true; }
dpkg-query -W -f='${Status}' docker-ce 2>/dev/null | grep -q "install ok installed" && {
    print_warn "Removing existing Docker installation..."
    apt-get --allow-remove-essential -y purge \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
    rm -rf /var/lib/docker /etc/docker || true; traces=true; }
# Clean up firewall packages from previous runs that conflict with our approach.
# We use direct iptables + xinle-firewall.service (no UFW, no iptables-persistent).
for _pkg in ufw iptables-persistent netfilter-persistent; do
    dpkg-query -W -f='${Status}' "$_pkg" 2>/dev/null | grep -q "install ok installed" && {
        print_warn "Removing '${_pkg}' from previous run (conflicts with direct iptables approach)..."
        DEBIAN_FRONTEND=noninteractive apt-get -y purge "$_pkg" 2>/dev/null || true
        traces=true; } || true
done
# Remove stale Docker networks and bridges from previous failed installs.
# A failed install leaves orphan bridge interfaces (e.g. br-XXXXXXXX) with the
# same 172.20.0.0/16 subnet as the current live network.  Linux then installs
# two kernel routes for that prefix and the stale (DOWN) bridge wins, black-
# holing all container traffic even though docker ps shows containers as "Up".
if command -v docker >/dev/null 2>&1; then
    # Collect all Docker-managed bridge names from live networks
    live_bridges=$(docker network ls -q 2>/dev/null | \
        xargs -I{} docker network inspect {} --format '{{.Options.com.docker.network.bridge.name}} {{.Id}}' 2>/dev/null | \
        awk '{print $1}' | grep -v '^$' || true)
    # Also collect bridges referenced by running containers
    live_bridges+=$(docker network ls --format '{{.ID}}' 2>/dev/null | \
        xargs -I{} sh -c 'docker network inspect {} --format "br-{{slice .Id 0 12}}" 2>/dev/null' || true)

    # Find all br-* interfaces that are DOWN (no carrier) and not in live_bridges
    while IFS= read -r iface; do
        iface_name=$(echo "$iface" | awk '{print $1}')
        # Skip if this bridge is still referenced by a live Docker network
        if echo "$live_bridges" | grep -qF "$iface_name"; then
            continue
        fi
        state=$(ip link show "$iface_name" 2>/dev/null | grep -oE 'state [A-Z]+' | awk '{print $2}')
        if [ "$state" = "DOWN" ]; then
            print_warn "Removing stale Docker bridge: ${iface_name} (state DOWN, not in any live network)"
            ip route del 172.20.0.0/16 dev "$iface_name" 2>/dev/null || true
            ip route del 172.17.0.0/16 dev "$iface_name" 2>/dev/null || true
            ip link set "$iface_name" down 2>/dev/null || true
            ip link delete "$iface_name" 2>/dev/null || true
            traces=true
        fi
    done < <(ip link show type bridge 2>/dev/null | grep '^[0-9]' | awk '{print $2}' | tr -d ':'  | grep '^br-')

    # Prune dangling Docker networks (networks with no containers)
    docker network prune -f 2>/dev/null | grep -v '^$' | while IFS= read -r line; do
        print_info "Docker network prune: $line"; done || true
fi

# Remove stale xinle-firewall.service if present from a previous run
[ -f /etc/systemd/system/xinle-firewall.service ] && {
    systemctl stop xinle-firewall.service 2>/dev/null || true
    systemctl disable xinle-firewall.service 2>/dev/null || true
    rm -f /etc/systemd/system/xinle-firewall.service
    systemctl daemon-reload 2>/dev/null || true
    print_info "Removed stale xinle-firewall.service from previous run."
    traces=true; } || true
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
# Determine whether a full Docker install is needed.
# We check for the docker-ce package (not just the binary) because a previous
# failed run may have left a broken partial install where the binary is missing
# but the apt guard would skip reinstall.
DOCKER_PKG_OK=false
if dpkg-query -W -f='${Status}' docker-ce 2>/dev/null | grep -q 'install ok installed'; then
    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        DOCKER_PKG_OK=true
        print_info "Docker already installed and running — skipping install."
    else
        print_warn "Docker package present but binary missing or daemon not running. Reinstalling..."
    fi
fi
if [ "$DOCKER_PKG_OK" = false ]; then
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

# Refresh PATH and shell command cache so docker is found immediately
# without needing a new shell session. Docker installs to /usr/bin but
# the running shell may have cached a 'not found' result for that path.
export PATH="/usr/bin:/usr/local/bin:$PATH"
hash -r 2>/dev/null || true

# Wait for the Docker daemon socket to be ready — systemd starts it
# asynchronously after package install and it may not be available yet.
DOCKER_WAIT=0
while [ $DOCKER_WAIT -lt 30 ]; do
    if docker info &>/dev/null; then
        break
    fi
    print_info "Waiting for Docker daemon... (${DOCKER_WAIT}s)"
    sleep 2
    DOCKER_WAIT=$((DOCKER_WAIT + 2))
done

STATE_DOCKER_INSTALLED=true
print_ok "Docker $(docker --version) ready."

# =============================================================================
#  STAGE 6: GRAFANA ALLOY — SKIPPED (deployed as Docker container post-install)
# =============================================================================
print_header "Stage 6: Grafana Alloy"
#
# NOTE: Alloy is NOT installed as a system package here.
# The Alloy apt post-install script unconditionally calls 'systemctl start alloy'
# which hangs indefinitely on a VPS because alloy attempts to connect to the
# remote Prometheus write endpoint before the network/VPN tunnel is up.
# policy-rc.d exit 101 was attempted but Alloy's post-install bypasses it.
#
# Resolution: Alloy runs as a Docker container (grafana/alloy) defined in
# docker-compose.yml, started in Stage 10 alongside all other services.
# The container has restart: unless-stopped and will retry on its own.
#
print_warn "Alloy system package install SKIPPED — will start as Docker container in Stage 10."
print_info "Config: ${PROJECT_DEST}/monitoring/alloy-config.alloy"
# STATE_ALLOY_INSTALLED intentionally left false — nothing to roll back here

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
# n8n runs as the 'node' user (UID 1000) inside the container — must own its data dir
chown -R 1000:1000 "${DOCKER_APPS_DIR}/n8n"
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
#  STAGE 8b: FIREWALL VERIFICATION
# =============================================================================
# The IPsec script (Stage 8) already applied all required iptables rules
# directly and created xinle-firewall.service for boot-time persistence.
# No UFW or iptables-persistent is used — zero package conflicts.
print_header "Stage 8b: Firewall Verification"
print_ok "iptables rules applied by Stage 8: SSH(22), HTTP(80), NPM Admin(81), HTTPS(443), IPsec(500/4500)."
print_ok "xinle-firewall.service enabled — rules will persist across reboots."
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
    sed "s|\${MYSQL_PASSWORD}|${MYSQL_PASSWORD}|g" \
        "${PROJECT_DEST}/scripts/netlock-web-appsettings.json" \
        > "${DOCKER_APPS_DIR}/netlockrmm/web/appsettings.json"
    print_ok "Seeded netlockrmm-web appsettings.json"
}
chown -R "$TARGET_USER":"$TARGET_USER" "${DOCKER_APPS_DIR}/netlockrmm"

# =============================================================================
#  STAGE 10: PULL DOCKER IMAGES  (animated per-service progress)
# =============================================================================
print_header "Stage 10: Pulling Docker Images"
cd "$PROJECT_DEST"

# Colour / style shortcuts
_BLD="\e[1m"
_DIM="\e[2m"
_RST="\e[0m"
_GRN="\e[1;32m"
_CYN="\e[1;36m"
_YLW="\e[1;33m"
_RED="\e[1;31m"
_MGN="\e[1;35m"
_WHT="\e[1;37m"

# Spinner frames
_SPIN=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')

spin_start() {
    # spin_start "label"  — runs spinner in background, stores PID in _SPIN_PID
    local label="$1"
    (
        local i=0
        while true; do
            printf "\r  ${_CYN}${_SPIN[$i]}${_RST}  %-40s" "$label"
            i=$(( (i+1) % ${#_SPIN[@]} ))
            sleep 0.08
        done
    ) &
    _SPIN_PID=$!
    disown $_SPIN_PID
}

spin_stop_ok() {
    local label="$1"
    kill $_SPIN_PID 2>/dev/null; wait $_SPIN_PID 2>/dev/null || true
    printf "\r  ${_GRN}✔${_RST}  %-40s ${_DIM}done${_RST}\n" "$label"
}

spin_stop_warn() {
    local label="$1"
    kill $_SPIN_PID 2>/dev/null; wait $_SPIN_PID 2>/dev/null || true
    printf "\r  ${_YLW}⚠${_RST}  %-40s ${_YLW}cached/skipped${_RST}\n" "$label"
}

# Pull image map — friendly name : compose service name
declare -A SVC_LABELS=(
    [npm]="Nginx Proxy Manager"
    [postgres]="PostgreSQL 16"
    [mysql]="MySQL 8.0"
    [n8n]="n8n Workflow Engine"
    [forgejo]="Forgejo Git Server"
    [pgadmin]="pgAdmin 4"
    [phpmyadmin]="phpMyAdmin"
    [netlockrmm-server]="NetLock RMM Server"
    [netlockrmm-web]="NetLock RMM Web Console"
    [alloy]="Grafana Alloy"
)

echo ""
printf "  ${_WHT}%-3s  %-30s  %s${_RST}\n" "   " "Service" "Image"
printf "  ${_DIM}%s${_RST}\n" "────────────────────────────────────────────────────"

PULL_ERRORS=()
SVC_NUM=0
SVC_TOTAL=$(docker compose config --services | wc -l)

while IFS= read -r svc; do
    SVC_NUM=$((SVC_NUM + 1))
    label="${SVC_LABELS[$svc]:-$svc}"
    img=$(docker compose config --format json 2>/dev/null | \
          python3 -c "import sys,json; d=json.load(sys.stdin); \
          print(d['services'].get('${svc}',{}).get('image',''))" 2>/dev/null || echo "")
    display="${label}"
    [ -n "$img" ] && display="${label}"

    spin_start "[${SVC_NUM}/${SVC_TOTAL}] ${display}"

    if docker compose pull "$svc" > /tmp/pull_${svc}.log 2>&1; then
        spin_stop_ok "[${SVC_NUM}/${SVC_TOTAL}] ${display}"
    else
        spin_stop_warn "[${SVC_NUM}/${SVC_TOTAL}] ${display}"
        PULL_ERRORS+=("$svc")
    fi
done < <(docker compose config --services)

echo ""
if [ ${#PULL_ERRORS[@]} -gt 0 ]; then
    print_warn "Some images could not be pulled: ${PULL_ERRORS[*]}"
    print_warn "Cached images will be used where available."
else
    print_ok "All images pulled successfully."
fi

# =============================================================================
#  STAGE 11: START ALL DOCKER SERVICES  (animated healthcheck monitor)
# =============================================================================
print_header "Stage 11: Starting All Docker Services"

# Start containers with --no-deps first for MySQL alone so we can watch it
# independently, then bring everything up.
# Use set +e so a healthcheck failure doesn't immediately fire the ERR trap
# before we get a chance to dump container logs.

dump_failed_containers() {
    echo ""
    print_error "One or more containers failed — dumping logs for diagnosis:"
    echo ""
    for cname in $(docker ps -a --format '{{.Names}}' 2>/dev/null); do
        cstatus=$(docker inspect --format='{{.State.Status}}' "$cname" 2>/dev/null || echo "unknown")
        chealth=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}'                   "$cname" 2>/dev/null || echo "none")
        if [[ "$cstatus" == "exited" ]] || [[ "$chealth" == "unhealthy" ]]; then
            echo -e "  ${_RED}━━━━━  $cname  [status=$cstatus  health=$chealth]  ━━━━━${_RST}"
            docker logs --tail 60 "$cname" 2>&1 | sed 's/^/    /'
            echo ""
        fi
    done
}

# Step 1 — Start MySQL alone first so we can see its logs if it fails
print_info "Starting MySQL first (isolated healthcheck)..."
set +e
docker compose up -d --no-deps mysql 2>&1
MYSQL_EXIT=$?
set -e

if [ $MYSQL_EXIT -ne 0 ]; then
    dump_failed_containers
    exit 1
fi

# Wait up to 90s for MySQL to become healthy before starting dependents
print_info "Waiting for MySQL to become healthy (up to 90s)..."
MYSQL_WAIT=0
while [ $MYSQL_WAIT -lt 90 ]; do
    mhealth=$(docker inspect --format='{{.State.Health.Status}}' mysql 2>/dev/null || echo "unknown")
    printf "
  ${_CYN}⠿${_RST}  mysql health: %-12s  %ds" "$mhealth" "$MYSQL_WAIT"
    if [ "$mhealth" = "healthy" ]; then
        echo ""
        print_ok "MySQL is healthy."
        break
    fi
    if [ "$mhealth" = "unhealthy" ]; then
        echo ""
        dump_failed_containers
        exit 1
    fi
    sleep 5
    MYSQL_WAIT=$((MYSQL_WAIT + 5))
done

if [ "$(docker inspect --format='{{.State.Health.Status}}' mysql 2>/dev/null)" != "healthy" ]; then
    echo ""
    dump_failed_containers
    exit 1
fi

# Step 2 — Start everything else
print_info "Starting all remaining services..."
set +e
docker compose up -d 2>&1
COMPOSE_EXIT=$?
set -e

STATE_DOCKER_COMPOSE_UP=true

if [ $COMPOSE_EXIT -ne 0 ]; then
    dump_failed_containers
    exit 1
fi

echo ""
print_info "Waiting for all containers to become healthy..."
echo ""

# Monitor container health with live status table
MONITOR_TIMEOUT=180   # seconds before giving up
MONITOR_INTERVAL=5
MONITOR_ELAPSED=0
ALL_HEALTHY=false

# Services that have healthchecks defined
HEALTHY_SVCS=(postgres mysql npm)

while [ $MONITOR_ELAPSED -lt $MONITOR_TIMEOUT ]; do
    ALL_GOOD=true
    printf "\r\e[K"   # clear line

    STATUS_LINE=""
    for svc in "${HEALTHY_SVCS[@]}"; do
        state=$(docker inspect --format='{{.State.Health.Status}}' "$svc" 2>/dev/null || echo "none")
        case "$state" in
            healthy)   icon="${_GRN}●${_RST}" ;;
            starting)  icon="${_YLW}◌${_RST}" ;;
            unhealthy) icon="${_RED}✖${_RST}"; ALL_GOOD=false ;;
            *)         icon="${_DIM}○${_RST}" ;;
        esac
        STATUS_LINE+="  ${icon} ${_WHT}${svc}${_RST}"
        [ "$state" != "healthy" ] && [ "$state" != "none" ] && ALL_GOOD=false
    done

    printf "  %s    ${_DIM}%ds${_RST}" "$STATUS_LINE" "$MONITOR_ELAPSED"

    if $ALL_GOOD; then
        ALL_HEALTHY=true
        break
    fi

    # Check for any unhealthy containers — dump logs and fail fast
    UNHEALTHY=$(docker ps --filter health=unhealthy --format '{{.Names}}' 2>/dev/null || true)
    if [ -n "$UNHEALTHY" ]; then
        echo ""
        print_error "Unhealthy containers: $UNHEALTHY"
        echo ""
        for uc in $UNHEALTHY; do
            echo -e "  ${_RED}━━━━  $uc logs (last 40 lines)  ━━━━${_RST}"
            docker logs --tail 40 "$uc" 2>&1 | sed 's/^/    /'
            echo ""
        done
        exit 1
    fi

    sleep $MONITOR_INTERVAL
    MONITOR_ELAPSED=$((MONITOR_ELAPSED + MONITOR_INTERVAL))
done

echo ""
if $ALL_HEALTHY; then
    print_ok "All containers healthy."
else
    print_warn "Health monitor timed out — checking final state..."
fi

echo ""
# Final status table — coloured
printf "  ${_BLD}${_WHT}%-25s %-15s %-15s %s${_RST}\n" "CONTAINER" "STATUS" "HEALTH" "PORTS"
printf "  ${_DIM}%s${_RST}\n" "─────────────────────────────────────────────────────────────────"
while IFS= read -r line; do
    name=$(echo "$line" | awk '{print $1}')
    status=$(echo "$line" | awk '{print $2}')
    health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' \
             "$name" 2>/dev/null || echo "n/a")
    ports=$(echo "$line" | awk '{$1=$2=""; print $0}' | xargs)

    case "$health" in
        healthy)   hcol="${_GRN}" ;;
        unhealthy) hcol="${_RED}" ;;
        starting)  hcol="${_YLW}" ;;
        *)         hcol="${_DIM}" ;;
    esac
    case "$status" in
        running) scol="${_GRN}" ;;
        exited)  scol="${_RED}" ;;
        *)       scol="${_YLW}" ;;
    esac

    printf "  %-25s ${scol}%-15s${_RST} ${hcol}%-15s${_RST} %s\n" \
        "$name" "$status" "$health" "${ports:0:40}"
done < <(docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" \
         2>/dev/null | tail -n +2)
echo ""

# Re-enable apt-daily timers now that install is complete
systemctl start apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
restore_needrestart

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
