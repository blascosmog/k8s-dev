#!/bin/bash

################################################################################
# k8s-dev Installation Script
# 
# This script deploys Kubernetes manifests for a development environment.
# It performs pre-flight checks, creates necessary directories, and deploys
# applications in a safe, idempotent manner.
#
# Requirements:
# - Root/sudo access
# - Kubernetes cluster (K3s recommended)
# - kubectl configured
# - Storage at /mnt/apps (LVM recommended)
################################################################################

set -e          # Exit on error
set -u          # Exit on undefined variable
set -o pipefail # Exit on pipe failure

################################################################################
# CONFIGURATION
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${SCRIPT_DIR}/manifests"
STORAGE_BASE="/mnt/apps"
REQUIRED_APPS=("portainer" "heimdall" "n8n")

################################################################################
# COLOR CODES
################################################################################

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

################################################################################
# LOGGING FUNCTIONS
################################################################################

print_banner() {
    echo ""
    echo "================================================"
    echo "$1"
    echo "================================================"
    echo ""
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}" >&2
}

print_info() {
    echo -e "${YELLOW}ℹ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_step() {
    echo -e "${BLUE}▶ $1${NC}"
}

################################################################################
# PRE-FLIGHT CHECKS
################################################################################

check_root() {
    print_step "Checking for root/sudo privileges..."
    
    if [ "$EUID" -ne 0 ]; then
        print_warning "Not running as root. Attempting to use sudo..."
        
        if ! sudo -n true 2>/dev/null; then
            print_error "This script requires sudo privileges"
            print_info "Please run: sudo $0"
            exit 1
        fi
        
        print_success "Sudo access confirmed"
        # Re-execute script with sudo if not already root
        exec sudo bash "$0" "$@"
    else
        print_success "Running with root privileges"
    fi
}

check_kubectl() {
    print_step "Checking for kubectl..."
    
    if ! command -v kubectl &> /dev/null; then
        print_error "kubectl is not installed or not in PATH"
        print_info "Please install kubectl: https://kubernetes.io/docs/tasks/tools/"
        exit 1
    fi
    
    print_success "kubectl found: $(kubectl version --client --short 2>/dev/null || echo 'installed')"
}

check_cluster_connection() {
    print_step "Checking cluster connectivity..."
    
    if ! kubectl cluster-info &> /dev/null; then
        print_error "Cannot connect to Kubernetes cluster"
        print_info "Please ensure your kubeconfig is properly configured"
        print_info "For K3s, try: export KUBECONFIG=/etc/rancher/k3s/k3s.yaml"
        exit 1
    fi
    
    print_success "Connected to Kubernetes cluster"
    
    # Display cluster info
    local node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
    print_info "Cluster has ${node_count} node(s)"
}

check_storage() {
    print_step "Checking storage requirements..."
    
    if [ ! -d "${STORAGE_BASE}" ]; then
        print_error "Storage directory ${STORAGE_BASE} does not exist"
        print_info "This script expects an LVM volume mounted at ${STORAGE_BASE}"
        print_info "Please create the required storage:"
        print_info "  sudo mkdir -p ${STORAGE_BASE}"
        print_info "  sudo chown -R 1000:1000 ${STORAGE_BASE}"
        exit 1
    fi
    
    print_success "Storage base directory exists: ${STORAGE_BASE}"
    
    # Check if it's writable
    if [ ! -w "${STORAGE_BASE}" ]; then
        print_warning "Storage directory is not writable, attempting to fix permissions..."
        chown -R 1000:1000 "${STORAGE_BASE}" 2>/dev/null || true
    fi
    
    # Check available space
    local available_space=$(df -BG "${STORAGE_BASE}" | awk 'NR==2 {print $4}' | sed 's/G//')
    if [ "${available_space}" -lt 10 ]; then
        print_warning "Low disk space: ${available_space}GB available at ${STORAGE_BASE}"
    else
        print_info "Available space: ${available_space}GB"
    fi
}

check_manifests() {
    print_step "Checking for manifest files..."
    
    if [ ! -d "${MANIFESTS_DIR}" ]; then
        print_error "Manifests directory not found: ${MANIFESTS_DIR}"
        exit 1
    fi
    
    local manifest_count=$(find "${MANIFESTS_DIR}" -name "*.yaml" -o -name "*.yml" | wc -l)
    print_success "Found ${manifest_count} manifest file(s)"
}

run_preflight_checks() {
    print_banner "PRE-FLIGHT CHECKS"
    
    check_root
    check_kubectl
    check_cluster_connection
    check_storage
    check_manifests
    
    print_success "All pre-flight checks passed!"
    echo ""
}

################################################################################
# STORAGE SETUP
################################################################################

setup_storage_directories() {
    print_banner "STORAGE SETUP"
    print_step "Creating application directories..."
    
    for app in "${REQUIRED_APPS[@]}"; do
        local app_dir="${STORAGE_BASE}/${app}"
        
        if [ -d "${app_dir}" ]; then
            print_info "${app}: Directory already exists (idempotent)"
        else
            mkdir -p "${app_dir}"
            chown -R 1000:1000 "${app_dir}"
            chmod -R 755 "${app_dir}"
            print_success "${app}: Directory created at ${app_dir}"
        fi
    done
    
    echo ""
}

################################################################################
# DEPLOYMENT FUNCTIONS
################################################################################

is_deployed() {
    local resource_type=$1
    local resource_name=$2
    local namespace=${3:-default}
    
    kubectl get "${resource_type}" "${resource_name}" -n "${namespace}" &> /dev/null
}

apply_manifest() {
    local manifest=$1
    local description=$2
    
    if [ ! -f "${manifest}" ]; then
        print_error "Manifest not found: ${manifest}"
        return 1
    fi
    
    print_step "Deploying ${description}..."
    
    if kubectl apply -f "${manifest}"; then
        print_success "${description} deployed successfully"
        return 0
    else
        print_error "Failed to deploy ${description}"
        return 1
    fi
}

deploy_portainer() {
    print_step "Deploying Portainer (Container Management UI)..."
    
    # Check if already deployed
    if is_deployed "deployment" "portainer" "portainer"; then
        print_info "Portainer is already deployed (idempotent)"
        print_info "To redeploy, delete it first: kubectl delete -f manifests/portainer-admin.yaml"
    else
        apply_manifest "${MANIFESTS_DIR}/portainer-admin.yaml" "Portainer"
        print_info "Access Portainer at: http://YOUR_SERVER_IP:30777"
    fi
    
    echo ""
}

deploy_heimdall() {
    print_step "Deploying Heimdall (Application Dashboard)..."
    
    # Verify storage
    if [ ! -d "${STORAGE_BASE}/heimdall" ]; then
        print_warning "Heimdall storage directory not found, creating..."
        mkdir -p "${STORAGE_BASE}/heimdall"
        chown -R 1000:1000 "${STORAGE_BASE}/heimdall"
    fi
    
    if is_deployed "deployment" "heimdall-manual" "default"; then
        print_info "Heimdall is already deployed (idempotent)"
    else
        apply_manifest "${MANIFESTS_DIR}/heimdall-manual.yaml" "Heimdall"
        print_info "Access Heimdall at: http://YOUR_SERVER_IP:30088"
    fi
    
    echo ""
}

deploy_n8n() {
    print_step "Deploying n8n (Workflow Automation)..."
    
    # Verify storage
    if [ ! -d "${STORAGE_BASE}/n8n" ]; then
        print_warning "n8n storage directory not found, creating..."
        mkdir -p "${STORAGE_BASE}/n8n"
        chown -R 1000:1000 "${STORAGE_BASE}/n8n"
    fi
    
    if is_deployed "deployment" "n8n" "default"; then
        print_info "n8n is already deployed (idempotent)"
    else
        apply_manifest "${MANIFESTS_DIR}/n8n-deployment.yaml" "n8n"
        print_info "Access n8n at: http://YOUR_SERVER_IP:30080"
    fi
    
    echo ""
}

deploy_web_demo() {
    print_step "Deploying web-demo applications..."
    
    if [ ! -d "${MANIFESTS_DIR}/web-demo" ]; then
        print_warning "web-demo directory not found, skipping..."
        return 0
    fi
    
    local demo_manifests=$(find "${MANIFESTS_DIR}/web-demo" -name "*.yaml" -o -name "*.yml")
    
    if [ -z "${demo_manifests}" ]; then
        print_info "No web-demo manifests found, skipping..."
        return 0
    fi
    
    for manifest in ${demo_manifests}; do
        local filename=$(basename "${manifest}")
        apply_manifest "${manifest}" "web-demo/${filename}"
    done
    
    echo ""
}

deploy_all_manifests() {
    print_banner "DEPLOYING MANIFESTS"
    
    deploy_portainer
    deploy_heimdall
    deploy_n8n
    deploy_web_demo
    
    print_success "All manifests deployed!"
}

################################################################################
# STATUS & SUMMARY
################################################################################

show_deployment_status() {
    print_banner "DEPLOYMENT STATUS"
    
    print_step "Checking pod status..."
    kubectl get pods --all-namespaces | grep -E "portainer|heimdall|n8n|web-demo" || print_info "Pods may still be initializing..."
    
    echo ""
    print_step "Checking service endpoints..."
    kubectl get svc --all-namespaces | grep -E "portainer|heimdall|n8n|web-demo" || print_info "No services found"
    
    echo ""
}

show_summary() {
    print_banner "INSTALLATION COMPLETE!"
    
    print_success "All applications have been deployed successfully"
    echo ""
    
    print_info "Next Steps:"
    echo "  1. Wait for all pods to be in 'Running' state:"
    echo "     kubectl get pods --all-namespaces"
    echo ""
    echo "  2. Access your applications (replace YOUR_SERVER_IP with your actual IP):"
    echo "     • Portainer:  http://YOUR_SERVER_IP:30777"
    echo "     • Heimdall:   http://YOUR_SERVER_IP:30088"
    echo "     • n8n:        http://YOUR_SERVER_IP:30080"
    echo "     • Web Demo:   http://YOUR_SERVER_IP:30090"
    echo ""
    
    print_info "Storage locations:"
    echo "     All application data is stored at: ${STORAGE_BASE}"
    echo ""
    
    print_info "Useful commands:"
    echo "     kubectl get all --all-namespaces    # View all resources"
    echo "     kubectl logs <pod-name>             # View pod logs"
    echo "     kubectl describe pod <pod-name>     # Debug pod issues"
    echo ""
    
    print_warning "Security Reminder:"
    echo "     Remember to set strong passwords on first login!"
    echo "     This is a development environment - do not expose to the internet."
    echo ""
}

################################################################################
# MAIN EXECUTION
################################################################################

main() {
    print_banner "k8s-dev Installation Script"
    
    # Run all pre-flight checks first
    run_preflight_checks
    
    # Setup storage
    setup_storage_directories
    
    # Deploy all manifests
    deploy_all_manifests
    
    # Show status
    show_deployment_status
    
    # Show summary
    show_summary
}

# Execute main function
main "$@"
