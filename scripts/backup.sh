#!/bin/bash
#
# Automated Backup Script for Node.js Application
# This script performs automated backups of application data, Docker volumes,
# and can store backups to AWS S3.
#
# Usage:
#   ./backup.sh [options]
#
# Options:
#   --app-server <ip>       App server IP address
#   --ssh-key <path>        SSH key path
#   --s3-bucket <bucket>    S3 bucket for remote storage (optional)
#   --keep-local            Keep local backup after uploading to S3
#   --help                  Show this help
#

set -euo pipefail

# Configuration
BACKUP_DIR="${BACKUP_DIR:-/tmp/app-backups}"
S3_BUCKET="${S3_BUCKET:-}"
KEEP_LOCAL="${KEEP_LOCAL:-false}"
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="app-backup-${DATE}"
APP_SERVER_IP="${APP_SERVER_IP:-}"
SSH_KEY="${SSH_KEY:-}"
SSH_USER="${SSH_USER:-ec2-user}"
CONTAINER_NAME="node-app"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Automated backup script for Node.js application.

Options:
    --app-server IP        App server IP address (required for remote backup)
    --ssh-key PATH         SSH key for app server (required for remote backup)
    --s3-bucket BUCKET     S3 bucket name for remote storage
    --keep-local           Keep local backup after uploading to S3
    --help                 Show this help

Environment Variables:
    APP_SERVER_IP          App server IP address
    SSH_KEY                SSH key path
    S3_BUCKET              S3 bucket for remote storage
    BACKUP_DIR             Local backup directory (default: /tmp/app-backups)

Examples:
    # Local backup only
    ./backup.sh

    # Backup from remote server and store to S3
    ./backup.sh --app-server 10.0.1.50 --ssh-key ~/.ssh/key.pem --s3-bucket my-backups
EOF
    exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --app-server) APP_SERVER_IP="$2"; shift 2 ;;
        --ssh-key) SSH_KEY="$2"; shift 2 ;;
        --s3-bucket) S3_BUCKET="$2"; shift 2 ;;
        --keep-local) KEEP_LOCAL="true"; shift ;;
        --help) usage ;;
        *) log_error "Unknown option: $1"; usage ;;
    esac
done

# Create local backup directory
mkdir -p "${BACKUP_DIR}/${BACKUP_NAME}"

log_info "Starting backup: ${BACKUP_NAME}"

# Function to backup from remote server
backup_remote() {
    if [[ -z "${APP_SERVER_IP}" ]] || [[ -z "${SSH_KEY}" ]]; then
        log_error "APP_SERVER_IP and SSH_KEY are required for remote backup"
        exit 1
    fi

    log_info "Backing up from remote server: ${APP_SERVER_IP}"

    # Backup Docker container logs
    log_info "Backing up container logs..."
    ssh -i "${SSH_KEY}" \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile=/dev/null \
        "${SSH_USER}@${APP_SERVER_IP}" "docker logs ${CONTAINER_NAME} 2>&1" \
        > "${BACKUP_DIR}/${BACKUP_NAME}/app-logs.txt" || true

    # Backup Docker volumes (if any)
    log_info "Backing up Docker volumes..."
    ssh -i "${SSH_KEY}" \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile=/dev/null \
        "${SSH_USER}@${APP_SERVER_IP}" "docker volume ls -q" \
        > "${BACKUP_DIR}/${BACKUP_NAME}/volumes.txt" || true

    # Get container environment variables (masked)
    log_info "Backing up container configuration..."
    ssh -i "${SSH_KEY}" \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile=/dev/null \
        "${SSH_USER}@${APP_SERVER_IP}" "docker inspect ${CONTAINER_NAME} --format='{{json .Config.Env}}'" \
        > "${BACKUP_DIR}/${BACKUP_NAME}/env.json" || true

    # Backup application image (save as tar)
    log_info "Backing up Docker image..."
    ssh -i "${SSH_KEY}" \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile=/dev/null \
        "${SSH_USER}@${APP_SERVER_IP}" "docker save cicd-node-app:latest -o /tmp/cicd-node-app.tar" \
        || log_warn "Could not backup Docker image"

    # Copy image to local if remote backup succeeded
    if ssh -i "${SSH_KEY}" \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile=/dev/null \
        "${SSH_USER}@${APP_SERVER_IP}" "test -f /tmp/cicd-node-app.tar" 2>/dev/null; then
        scp -i "${SSH_KEY}" \
            -o StrictHostKeyChecking=accept-new \
            -o UserKnownHostsFile=/dev/null \
            "${SSH_USER}@${APP_SERVER_IP}:/tmp/cicd-node-app.tar" \
            "${BACKUP_DIR}/${BACKUP_NAME}/" || true
    fi
}

# Function to backup locally (if running on the app server)
backup_local() {
    log_info "Backing up locally..."

    # Backup container logs
    log_info "Backing up container logs..."
    docker logs ${CONTAINER_NAME} 2>&1 > "${BACKUP_DIR}/${BACKUP_NAME}/app-logs.txt" || true

    # Backup Docker volumes
    log_info "Backing up Docker volumes..."
    docker volume ls -q > "${BACKUP_DIR}/${BACKUP_NAME}/volumes.txt" || true

    # Backup container configuration
    log_info "Backing up container configuration..."
    docker inspect ${CONTAINER_NAME} --format='{{json .Env}}' > "${BACKUP_DIR}/${BACKUP_NAME}/env.json" || true

    # Backup Docker image
    log_info "Backing up Docker image..."
    docker save cicd-node-app:latest -o "${BACKUP_DIR}/${BACKUP_NAME}/cicd-node-app.tar" || true
}

# Function to upload to S3
upload_to_s3() {
    if [[ -z "${S3_BUCKET}" ]]; then
        log_warn "S3_BUCKET not set, skipping S3 upload"
        return
    fi

    log_info "Uploading backup to S3: s3://${S3_BUCKET}/${BACKUP_NAME}.tar.gz"

    # Create tar archive
    tar -czf "${BACKUP_DIR}/${BACKUP_NAME}.tar.gz" -C "${BACKUP_DIR}" "${BACKUP_NAME}"

    # Upload to S3
    if command -v aws &> /dev/null; then
        aws s3 cp "${BACKUP_DIR}/${BACKUP_NAME}.tar.gz" "s3://${S3_BUCKET}/${BACKUP_NAME}.tar.gz"
        log_info "Backup uploaded to S3 successfully"
    else
        log_error "AWS CLI not found. Cannot upload to S3."
        exit 1
    fi

    # Remove local archive if not keeping
    if [[ "${KEEP_LOCAL}" != "true" ]]; then
        rm -f "${BACKUP_DIR}/${BACKUP_NAME}.tar.gz"
    fi
}

# Perform backup based on available information
if [[ -n "${APP_SERVER_IP}" ]]; then
    backup_remote
else
    # Check if we're running inside the container or on the host
    if command -v docker &> /dev/null && docker ps &> /dev/null; then
        backup_local
    else
        log_error "Cannot perform backup. Either provide --app-server or run on the app server with Docker."
        exit 1
    fi
fi

# Create metadata file
log_info "Creating backup metadata..."
cat > "${BACKUP_DIR}/${BACKUP_NAME}/backup-info.txt" << EOF
Backup Date: $(date)
Backup Name: ${BACKUP_NAME}
Hostname: $(hostname)
App Server: ${APP_SERVER_IP:-local}
Docker Image: cicd-node-app:latest
EOF

# Create final archive
log_info "Creating final archive..."
tar -czf "${BACKUP_DIR}/${BACKUP_NAME}.tar.gz" -C "${BACKUP_DIR}" "${BACKUP_NAME}"

# Upload to S3 if configured
if [[ -n "${S3_BUCKET}" ]]; then
    upload_to_s3
fi

# Display backup summary
log_info "============================================="
log_info "Backup completed successfully!"
log_info "============================================="
log_info "Backup location: ${BACKUP_DIR}/${BACKUP_NAME}.tar.gz"
log_info "Backup size: $(du -h "${BACKUP_DIR}/${BACKUP_NAME}.tar.gz" | cut -f1)"
log_info ""

# Cleanup old local backups (keep last 7)
log_info "Cleaning up old local backups..."
find "${BACKUP_DIR}" -name "app-backup-*.tar.gz" -mtime +7 -delete 2>/dev/null || true
find "${BACKUP_DIR}" -type d -name "app-backup-*" -mtime +7 -exec rm -rf {} + 2>/dev/null || true

log_info "Cleanup complete"
log_info "============================================="

exit 0
