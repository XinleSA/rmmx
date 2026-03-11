#!/bin/bash
#############################################################################
# Author: James Barrett | Company: Xinle, LLC
# Version: 6.1.0
# Created: March 11, 2025
# Last Modified: March 11, 2025
#############################################################################
#
#  Xinle 欣乐 — GitHub to Forgejo Migration Script
#
#  Migrates all repositories from a specified GitHub user account to your
#  self-hosted Forgejo instance at https://rmmx.xinle.biz/git
#############################################################################

set -euo pipefail

# --- Configuration ---
readonly GITHUB_REPO="XinleSA/rmmx"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# --- Helper Functions ---
print_header() { echo -e "\n\e[1;35m##############################################################################\e[0m"; echo -e "\e[1;35m  $1\e[0m"; echo -e "\e[1;35m##############################################################################\e[0m"; }
print_info()   { echo -e "\e[1;36m  [INFO]  $1\e[0m"; }
print_ok()     { echo -e "\e[1;32m  [OK]    $1\e[0m"; }
print_warn()   { echo -e "\e[1;33m  [WARN]  $1\e[0m"; }
print_error()  { echo -e "\e[1;31m  [ERROR] $1\e[0m" >&2; }

# --- 1. Self-Update from GitHub ---
print_header "Checking for Script Updates from GitHub"

if [ -d "$PROJECT_ROOT/.git" ]; then
    cd "$PROJECT_ROOT"
    git pull origin main --rebase
    print_ok "Update check complete."
    cd "$SCRIPT_DIR"
else
    print_info "Not a git repository. Skipping self-update."
fi

# --- 2. Gather User Input ---
print_header "Gathering Migration Details"

read -rp "  Enter your GitHub username: " GITHUB_USER
read -rp "  Enter your Forgejo instance URL (e.g., https://rmmx.xinle.biz/git): " FORGEJO_URL
read -rs -p "  Enter your Forgejo Access Token: " FORGEJO_TOKEN
echo ""

if [ -z "$GITHUB_USER" ] || [ -z "$FORGEJO_URL" ] || [ -z "$FORGEJO_TOKEN" ]; then
    print_error "All inputs are required. Aborting."
    exit 1
fi

# Strip trailing slash from Forgejo URL
FORGEJO_URL="${FORGEJO_URL%/}"

# --- 3. Run Migration ---
print_header "Starting Repository Migration from GitHub user: ${GITHUB_USER}"

# Fetch all repos from GitHub API (handles pagination up to 100 repos)
REPOS=$(curl -s "https://api.github.com/users/${GITHUB_USER}/repos?per_page=100" \
    | grep -o '"clone_url": "[^"]*' \
    | awk -F'"' '{print $4}')

if [ -z "$REPOS" ]; then
    print_warn "No public repositories found for GitHub user '${GITHUB_USER}'."
    exit 0
fi

REPO_COUNT=0
FAIL_COUNT=0

for REPO_URL in $REPOS; do
    REPO_NAME=$(basename "$REPO_URL" .git)
    print_info "Migrating: ${REPO_NAME} ..."

    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "${FORGEJO_URL}/api/v1/repos/migrate" \
        -H "Authorization: token ${FORGEJO_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{
              \"clone_addr\": \"${REPO_URL}\",
              \"repo_name\": \"${REPO_NAME}\",
              \"mirror\": false,
              \"private\": false
            }")

    if [ "$HTTP_STATUS" -eq 201 ]; then
        print_ok "  Migrated: ${REPO_NAME}"
        REPO_COUNT=$((REPO_COUNT + 1))
    else
        print_warn "  Failed to migrate '${REPO_NAME}' (HTTP ${HTTP_STATUS}). May already exist."
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
done

print_header "Migration Complete"
echo ""
echo "  Migrated : ${REPO_COUNT} repositories"
echo "  Failed   : ${FAIL_COUNT} repositories"
echo "  Forgejo  : ${FORGEJO_URL}"
echo ""
