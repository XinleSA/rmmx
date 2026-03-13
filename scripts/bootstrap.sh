#!/bin/bash
#############################################################################
# Author: James Barrett | Company: Xinle, LLC
# Version: 1.2.0
# Created: March 11, 2025
# Last Modified: March 13, 2026
#############################################################################
#
#  Xinle 欣乐 — Bootstrap Launcher
#
#  THIS is the script that curl downloads. Its only job is to:
#    1. Ensure git and curl are installed
#    2. Clone or update the repo to disk
#    3. Hand off to the REAL setup script (01_master_setup.sh) from DISK
#       with stdin connected to the terminal
#
#  Because this script is tiny and completes before any 'read' is called,
#  the pipe/stdin problem is fully avoided. The real setup script runs
#  from a file with a proper terminal stdin.
#
#  Usage (the one command you run):
#    curl -fsSL https://raw.githubusercontent.com/XinleSA/rmmx/main/scripts/bootstrap.sh | sudo bash
#############################################################################

set -euo pipefail

readonly GITHUB_REPO="XinleSA/rmmx"
readonly PROJECT_DEST="/home/ubuntu/xinle-infra"

# Embedded PAT for authenticated clone and log push — repo scope only
readonly GITHUB_PAT="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"

# --- Colors ---
G='\e[1;32m'; C='\e[1;36m'; R='\e[1;31m'; Y='\e[1;33m'; P='\e[1;35m'; NC='\e[0m'

echo ""
echo -e "${P}################################################################################${NC}"
echo -e "${P}  Xinle 欣乐 — Bootstrap Launcher v1.2.0${NC}"
echo -e "${P}  Fetching latest installer from GitHub...${NC}"
echo -e "${P}################################################################################${NC}"
echo ""

# Root check
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${R}  [ERROR] This script must be run as root or with sudo.${NC}"
    exit 1
fi

# Install git/curl if missing
if ! command -v git &>/dev/null || ! command -v curl &>/dev/null; then
    echo -e "${C}  [INFO]  Installing git and curl...${NC}"
    apt-get update -qq && apt-get install -y git curl
fi

export GITHUB_PAT

# Build the authenticated remote URL
CLONE_URL="https://${GITHUB_PAT}@github.com/${GITHUB_REPO}.git"

# Clone or update the repo
if [ ! -d "${PROJECT_DEST}/.git" ]; then
    echo -e "${C}  [INFO]  Cloning repository to ${PROJECT_DEST}...${NC}"
    git clone "$CLONE_URL" "$PROJECT_DEST"
    echo -e "${G}  [OK]    Repository cloned.${NC}"
else
    echo -e "${C}  [INFO]  Updating existing repository...${NC}"
    git config --global --add safe.directory "$PROJECT_DEST" 2>/dev/null || true
    # Update remote URL with PAT
    git -C "$PROJECT_DEST" remote set-url origin "$CLONE_URL"
    git -C "$PROJECT_DEST" fetch origin main
    git -C "$PROJECT_DEST" reset --hard origin/main
    echo -e "${G}  [OK]    Repository updated to latest.${NC}"
fi

# Confirm the real setup script exists
SETUP_SCRIPT="${PROJECT_DEST}/scripts/01_master_setup.sh"
if [ ! -f "$SETUP_SCRIPT" ]; then
    echo -e "${R}  [ERROR] Setup script not found at: ${SETUP_SCRIPT}${NC}"
    exit 1
fi

chmod +x "$SETUP_SCRIPT"

echo ""
echo -e "${G}  [OK]    Handing off to installer — stdin connected to terminal.${NC}"
echo ""

# Execute the real setup script FROM DISK with stdin from the terminal.
# This is the key: running from a file (not a pipe) means bash does NOT
# pre-read the entire script, and stdin is the user's terminal.
exec bash "$SETUP_SCRIPT" < /dev/tty
