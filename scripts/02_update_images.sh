#!/bin/bash
# =============================================================================
#  Xinle 欣乐 — System & Docker Update Script
# =============================================================================
#############################################################################
# Author: James Barrett | Company: Xinle, LLC
# Version: 8.2.0
# Created: March 11, 2025
# Last Modified: March 11, 2025
#############################################################################
#
#  Updates all system components:
#    1. Itself (by pulling from Git).
#    2. Grafana Alloy agent.
#    3. All Docker container images.
#
#  Usage:
#    ./02_update_images.sh               # Interactive mode (prompts for confirmation)
#    ./02_update_images.sh -y            # Unattended mode (assumes yes for all)
#    ./02_update_images.sh --install-cron  # Install daily 2:00 AM cron job (with -y)
#    ./02_update_images.sh -y --install-cron  # Both flags together
#    ./02_update_images.sh --help        # Display this help message
# =============================================================================

set -e

# --- Configuration ---
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
readonly SCRIPT_PATH="${SCRIPT_DIR}/02_update_images.sh"
# 2:00 AM Central Time = 08:00 UTC (CST, UTC-6) / 07:00 UTC (CDT, UTC-5)
# We use 08:00 UTC which covers 2:00 AM CST (standard time).
# During CDT (summer), this runs at 3:00 AM — acceptable for a maintenance window.
readonly CRON_SCHEDULE="0 8 * * *"
readonly CRON_JOB="${CRON_SCHEDULE} /bin/bash ${SCRIPT_PATH} -y >> /var/log/xinle-update.log 2>&1"
readonly CRON_MARKER="xinle-update"

# --- Parse Arguments ---
AUTO_YES=false
INSTALL_CRON=false

for arg in "$@"; do
    case "$arg" in
        -y)             AUTO_YES=true ;;
        --install-cron) INSTALL_CRON=true ;;
        --help|-h)
            echo ""
            echo -e "\e[1;35mXinle 欣乐 — System & Docker Update Script v8.2\e[0m"
            echo ""
            echo -e "\e[1;36mUSAGE\e[0m"
            echo "  sudo ./02_update_images.sh [OPTIONS]"
            echo ""
            echo -e "\e[1;36mOPTIONS\e[0m"
            printf "  %-22s %s\n" "(no arguments)"    "Interactive mode — prompts before each update step."
            printf "  %-22s %s\n" "-y"                "Unattended mode — auto-confirms all prompts. Used by cron."
            printf "  %-22s %s\n" "--install-cron"    "Install a daily cron job to run this script at 2:00 AM Central."
            printf "  %-22s %s\n" "--help, -h"        "Show this help message and exit."
            echo ""
            echo -e "\e[1;36mEXAMPLES\e[0m"
            printf "  %-45s %s\n" "sudo ./02_update_images.sh"                   "# Prompt before each step"
            printf "  %-45s %s\n" "sudo ./02_update_images.sh -y"                "# Update everything without prompting"
            printf "  %-45s %s\n" "sudo ./02_update_images.sh --install-cron"    "# Register the 2:00 AM daily cron job"
            printf "  %-45s %s\n" "sudo ./02_update_images.sh -y --install-cron" "# Register cron job AND run update now"
            echo ""
            echo -e "\e[1;36mCRON JOB DETAILS\e[0m"
            printf "  %-16s %s\n" "Schedule:"  "Daily at 08:00 UTC = 2:00 AM CST / 3:00 AM CDT"
            printf "  %-16s %s\n" "Log file:"  "/var/log/xinle-update.log"
            printf "  %-16s %s\n" "Duplicate:" "Existing cron job is detected and you are prompted before replacing."
            echo ""
            exit 0
            ;;
    esac
done

# --- Helper Functions ---
print_header() { echo -e "\n\e[1;35m--- $1 ---\e[0m"; }
print_info()   { echo -e "\e[1;36m  $1\e[0m"; }
print_warn()   { echo -e "\e[1;33m  WARNING: $1\e[0m"; }
print_ok()     { echo -e "\e[1;32m  OK: $1\e[0m"; }

confirm() {
    local prompt="$1"
    if [ "$AUTO_YES" = true ]; then
        print_info "Auto-yes enabled: $prompt — proceeding."
        return 0
    fi
    read -rp "  $prompt [y/N] " response
    [[ "$response" =~ ^[Yy]$ ]]
}

# =============================================================================
# OPTION: --install-cron
# =============================================================================
if [ "$INSTALL_CRON" = true ]; then
    print_header "Installing Daily Update Cron Job"

    # Check if the cron job already exists
    if crontab -l 2>/dev/null | grep -q "$CRON_MARKER"; then
        print_warn "A cron job with the marker '${CRON_MARKER}' already exists:"
        crontab -l 2>/dev/null | grep "$CRON_MARKER"
        echo ""
        if ! confirm "Do you want to replace the existing cron job?"; then
            print_info "Cron job installation skipped. No changes made."
            exit 0
        fi
        # Remove the existing entry
        crontab -l 2>/dev/null | grep -v "$CRON_MARKER" | crontab -
        print_info "Existing cron job removed."
    fi

    # Install the new cron job
    (crontab -l 2>/dev/null; echo "# ${CRON_MARKER}: daily update at 2:00 AM Central Time (08:00 UTC)"; echo "${CRON_JOB}") | crontab -

    print_ok "Cron job installed successfully."
    echo ""
    echo "  Schedule : Daily at 08:00 UTC (2:00 AM CST / 3:00 AM CDT)"
    echo "  Command  : ${SCRIPT_PATH} -y"
    echo "  Log file : /var/log/xinle-update.log"
    echo ""
    print_info "Current crontab:"
    crontab -l
    echo ""

    # If only --install-cron was passed (no -y to run updates now), exit cleanly
    if [ "$AUTO_YES" = false ] && ! confirm "Run the full update now as well?"; then
        print_info "Cron job installed. Exiting without running updates."
        exit 0
    fi
fi

# =============================================================================
# MAIN UPDATE PROCESS
# =============================================================================

print_header "Xinle 欣乐 — System & Docker Update (v8.2)"
echo "  Mode: $([ "$AUTO_YES" = true ] && echo "Unattended (-y)" || echo "Interactive")"
echo "  Time: $(date '+%Y-%m-%d %H:%M:%S %Z')"

# --- 1. Self-Update from GitHub ---
print_header "1/3 — Checking for Script Updates from GitHub"
cd "$PROJECT_ROOT"
git pull origin main --rebase
print_ok "Repository is up to date."

# --- 2. Update Grafana Alloy ---
print_header "2/3 — Updating Grafana Alloy Agent"
if confirm "Update Grafana Alloy to the latest version?"; then
    sudo apt-get update -qq
    sudo apt-get install -y --only-upgrade alloy
    print_ok "Grafana Alloy is up to date."
else
    print_info "Grafana Alloy update skipped."
fi

# --- 3. Update Docker Images ---
print_header "3/3 — Updating Docker Container Images"

if confirm "Pull latest Docker images and recreate updated containers?"; then
    cd "$PROJECT_ROOT"

    print_info "Pulling latest images for all services..."
    docker compose pull

    print_info "Re-creating containers with updated images (if any)..."
    docker compose up -d --remove-orphans

    print_info "Pruning old, unused Docker images..."
    docker image prune -f

    print_ok "Docker images updated."
else
    print_info "Docker image update skipped."
fi

# --- Done ---
print_header "Update Complete"
echo "  Finished: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo ""
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"
echo ""
