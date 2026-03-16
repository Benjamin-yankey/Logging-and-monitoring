#!/bin/bash
#
# Automated Monitoring Stack Deployment Script
# This script deploys the complete observability stack (Prometheus, Grafana, Jaeger, Alertmanager)
# to a remote monitoring server via SSH.
#
# Usage: 
#   ./monitoring-deploy.sh <monitoring-server-ip> <ssh-key-path> <ssh-user>
#
# Or set environment variables:
#   MONITORING_SERVER_IP=<ip> SSH_KEY=<path> SSH_USER=<user> ./monitoring-deploy.sh
#

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default values
MONITORING_SERVER_IP="${MONITORING_SERVER_IP:-}"
SSH_KEY="${SSH_KEY:-}"
SSH_USER="${SSH_USER:-ec2-user}"
CONTAINER_NAME="monitoring-stack"
PROMETHEUS_PORT=9090
GRAFANA_PORT=3000
JAEGER_PORT=16686
ALERTMANAGER_PORT=9093

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Usage function
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Deploy monitoring stack to a remote server.

Options:
    -i, --ip IP              Monitoring server IP address (required)
    -k, --key SSH_KEY        Path to SSH private key (required)
    -u, --user SSH_USER      SSH user (default: ec2-user)
    -h, --help               Show this help message

Environment Variables:
    MONITORING_SERVER_IP    Monitoring server IP address
    SSH_KEY                 Path to SSH private key
    SSH_USER                SSH user (default: ec2-user)

Examples:
    $0 -i 10.0.1.100 -k ~/.ssh/mykey.pem
    MONITORING_SERVER_IP=10.0.1.100 SSH_KEY=~/.ssh/mykey.pem $0
EOF
    exit 1
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -i|--ip)
            MONITORING_SERVER_IP="$2"
            shift 2
            ;;
        -k|--key)
            SSH_KEY="$2"
            shift 2
            ;;
        -u|--user)
            SSH_USER="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate required parameters
if [[ -z "${MONITORING_SERVER_IP}" ]]; then
    log_error "Monitoring server IP is required. Use -i or MONITORING_SERVER_IP"
    exit 1
fi

if [[ -z "${SSH_KEY}" ]]; then
    log_error "SSH key is required. Use -k or SSH_KEY"
    exit 1
fi

if [[ ! -f "${SSH_KEY}" ]]; then
    log_error "SSH key file not found: ${SSH_KEY}"
    exit 1
fi

log_info "Deploying monitoring stack to ${MONITORING_SERVER_IP}..."
log_info "Using SSH key: ${SSH_KEY}"
log_info "SSH user: ${SSH_USER}"

# Check SSH connectivity
log_info "Checking SSH connectivity..."
if ! ssh -i "${SSH_KEY}" \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 \
    "${SSH_USER}@${MONITORING_SERVER_IP}" "echo 'SSH connection successful'" 2>/dev/null; then
    log_error "Cannot connect to ${MONITORING_SERVER_IP}. Please check the IP and SSH access."
    exit 1
fi

# Check if Docker is installed
log_info "Checking Docker installation..."
if ! ssh -i "${SSH_KEY}" \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile=/dev/null \
    "${SSH_USER}@${MONITORING_SERVER_IP}" "docker --version" 2>/dev/null; then
    log_error "Docker is not installed on the monitoring server."
    exit 1
fi

# Check if Docker Compose is installed
if ! ssh -i "${SSH_KEY}" \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile=/dev/null \
    "${SSH_USER}@${MONITORING_SERVER_IP}" "docker compose version" 2>/dev/null; then
    log_warn "Docker Compose not found. Attempting to install..."
    ssh -i "${SSH_KEY}" \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile=/dev/null \
        "${SSH_USER}@${MONITORING_SERVER_IP}" "sudo apt-get update && sudo apt-get install -y docker-compose"
fi

# Create monitoring directory on remote server
log_info "Creating monitoring directory..."
ssh -i "${SSH_KEY}" \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile=/dev/null \
    "${SSH_USER}@${MONITORING_SERVER_IP}" "mkdir -p monitoring && cd monitoring"

# Copy monitoring configuration files
log_info "Copying monitoring configuration files..."
scp -i "${SSH_KEY}" \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile=/dev/null \
    ../monitoring/docker-compose.yml \
    ../monitoring/prometheus.yml \
    ../monitoring/alertmanager.yml \
    ../monitoring/alert_rules.yml \
    ../monitoring/grafana-dashboards/*.json \
    "${SSH_USER}@${MONITORING_SERVER_IP}:~/monitoring/"

# Update Prometheus configuration with the app server IP
log_info "Updating Prometheus configuration..."
ssh -i "${SSH_KEY}" \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile=/dev/null \
    "${SSH_USER}@${MONITORING_SERVER_IP}" "cd monitoring && sed -i 's/targets:.*/targets: [\"app-server:5000\"]/g' prometheus.yml"

# Stop and remove existing containers
log_info "Stopping existing monitoring containers..."
ssh -i "${SSH_KEY}" \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile=/dev/null \
    "${SSH_USER}@${MONITORING_SERVER_IP}" "cd monitoring && docker compose down || true"

# Start the monitoring stack
log_info "Starting monitoring stack..."
ssh -i "${SSH_KEY}" \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile=/dev/null \
    "${SSH_USER}@${MONITORING_SERVER_IP}" "cd monitoring && docker compose up -d"

# Wait for services to start
log_info "Waiting for services to start..."
sleep 10

# Check service status
log_info "Checking service status..."
ssh -i "${SSH_KEY}" \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile=/dev/null \
    "${SSH_USER}@${MONITORING_SERVER_IP}" "docker ps"

log_info "============================================="
log_info "Monitoring stack deployed successfully!"
log_info "============================================="
log_info "Services available at:"
log_info "  - Prometheus:   http://${MONITORING_SERVER_IP}:${PROMETHEUS_PORT}"
log_info "  - Grafana:      http://${MONITORING_SERVER_IP}:${GRAFANA_PORT}"
log_info "  - Jaeger:       http://${MONITORING_SERVER_IP}:${JAEGER_PORT}"
log_info "  - Alertmanager: http://${MONITORING_SERVER_IP}:${ALERTMANAGER_PORT}"
log_info ""
log_info "Default Grafana credentials: admin / admin"
log_info ""
log_info "To view logs: docker compose logs -f"
log_info "To stop:      docker compose down"
log_info "============================================="

exit 0
