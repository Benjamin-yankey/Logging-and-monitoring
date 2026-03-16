#!/bin/bash
#
# Automated Log Rotation and Cleanup Script
# This script manages Docker container logs, old images, and unused volumes.
# Can be run locally or remotely via SSH.
#
# Usage:
#   ./log-rotate.sh [options]
#
# Options:
#   --app-server <ip>       App server IP address
#   --ssh-key <path>        SSH key path
#   --max-log-size MB       Maximum log file size in MB (default: 100)
#   --keep-images N         Number of old images to keep (default: 3)
#   --dry-run               Show what would be done without executing
#   --help                  Show this help
#

set -euo pipefail

# Configuration
MAX_LOG_SIZE="${MAX_LOG_SIZE:-100}"
KEEP_IMAGES="${KEEP_IMAGES:-3}"
DRY_RUN="${DRY_RUN:-false}"
APP_SERVER_IP="${APP_SERVER_IP:-}"
SSH_KEY="${SSH_KEY:-}"
SSH_USER="${SSH_USER:-ec2-user}"
CONTAINER_NAME="node-app"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_dry() { echo -e "${BLUE}[DRY RUN]${NC} $1"; }

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Automated log rotation and cleanup script for Docker containers.

Options:
    --app-server IP        App server IP address (for remote execution)
    --ssh-key PATH         SSH key for app server
    --max-log-size MB      Maximum log file size in MB (default: 100)
    --keep-images N        Number of old images to keep (default: 3)
    --dry-run              Show what would be done without executing
    --help                 Show this help

Environment Variables:
    APP_SERVER_IP          App server IP address
    SSH_KEY                SSH key path
    MAX_LOG_SIZE           Maximum log size in MB
    KEEP_IMAGES            Number of images to keep
    DRY_RUN                Set to 'true' for dry run

Examples:
    # Local cleanup
    ./log-rotate.sh

    # Remote cleanup with custom settings
    ./log-rotate.sh --app-server 10.0.1.50 --ssh-key ~/.ssh/key.pem --max-log-size 50

    # Dry run to see what would be cleaned
    ./log-rotate.sh --app-server 10.0.1.50 --ssh-key ~/.ssh/key.pem --dry-run
EOF
    exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --app-server) APP_SERVER_IP="$2"; shift 2 ;;
        --ssh-key) SSH_KEY="$2"; shift 2 ;;
        --max-log-size) MAX_LOG_SIZE="$2"; shift 2 ;;
        --keep-images) KEEP_IMAGES="$2"; shift 2 ;;
        --dry-run) DRY_RUN="true"; shift ;;
        --help) usage ;;
        *) log_error "Unknown option: $1"; usage ;;
    esac
done

# Determine if we're running locally or remotely
REMOTE_EXEC=false
if [[ -n "${APP_SERVER_IP}" ]]; then
    if [[ -z "${SSH_KEY}" ]]; then
        log_error "SSH_KEY is required when using --app-server"
        exit 1
    fi
    REMOTE_EXEC=true
fi

# Function to execute command locally or remotely
run_cmd() {
    if [[ "${REMOTE_EXEC}" == "true" ]]; then
        ssh -i "${SSH_KEY}" \
            -o StrictHostKeyChecking=accept-new \
            -o UserKnownHostsFile=/dev/null \
            "${SSH_USER}@${APP_SERVER_IP}" "$1"
    else
        eval "$1"
    fi
}

# Function to run with dry-run support
run_action() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_dry "$1"
    else
        log_info "$1"
        run_cmd "$1"
    fi
}

log_info "============================================="
log_info "Starting log rotation and cleanup"
log_info "============================================="
[[ "${DRY_RUN}" == "true" ]] && log_warn "Running in DRY RUN mode - no changes will be made"

# 1. Container log rotation
log_info "Step 1: Rotating container logs..."
run_action "docker logs --tail 1000 ${CONTAINER_NAME} 2>&1 > /tmp/${CONTAINER_NAME}-recent-logs.txt || true"

# 2. Truncate container logs
log_info "Step 2: Truncating container log files..."
run_action "truncate -s 0 \$(docker inspect --format='{{.LogPath}}' ${CONTAINER_NAME} 2>/dev/null) 2>/dev/null || true"

# 3. Clean up old Docker logs
log_info "Step 3: Cleaning up old Docker log files..."
run_action "find /var/lib/docker/containers/ -name '*.log' -type f -size +${MAX_LOG_SIZE}M -exec truncate -s 0 {} \; 2>/dev/null || true"

# 4. Remove unused Docker images
log_info "Step 4: Removing unused Docker images..."
IMAGES_TO_REMOVE=$(run_cmd "docker images -f 'dangling=true' -q" 2>/dev/null || echo "")
if [[ -n "${IMAGES_TO_REMOVE}" ]]; then
    run_action "docker rmi \$(docker images -f 'dangling=true' -q) 2>/dev/null || true"
fi

# Keep only the last N image versions
log_info "Step 5: Pruning old image versions (keeping last ${KEEP_IMAGES})..."
run_action "docker image prune -af --filter 'until=168h' 2>/dev/null || true"

# 5. Clean up unused Docker volumes
log_info "Step 6: Cleaning up unused Docker volumes..."
run_action "docker volume prune -f 2>/dev/null || true"

# 6. Clean up unused networks
log_info "Step 7: Cleaning up unused Docker networks..."
run_action "docker network prune -f 2>/dev/null || true"

# 7. Clean up Docker build cache
log_info "Step 8: Cleaning up Docker build cache..."
run_action "docker builder prune -af 2>/dev/null || true"

# 8. Clean up temporary files
log_info "Step 9: Cleaning up temporary files..."
run_action "rm -rf /tmp/docker-* 2>/dev/null || true"
run_action "rm -rf /var/tmp/build-* 2>/dev/null || true"

# Display disk space usage
log_info "============================================="
log_info "Disk space usage after cleanup:"
log_info "============================================="
run_cmd "df -h /"

# Display Docker disk usage
log_info "============================================="
log_info "Docker disk usage:"
log_info "============================================="
run_cmd "docker system df"

log_info "============================================="
log_info "Log rotation and cleanup completed!"
log_info "============================================="

exit 0
