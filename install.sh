#!/bin/bash

################################################################################
# k8s-dev Installation Script
# 
# This script deploys Kubernetes manifests and Helm charts for a complete
# development environment. It performs pre-flight checks, creates necessary
# directories, and deploys applications in a safe, idempotent manner.
#
# Requirements:
# - Root/sudo access
# - Kubernetes cluster (K3s recommended)
# - kubectl and helm (auto-installed if missing)
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
HELM_VALUES_DIR="${SCRIPT_DIR}/helm-values"
STORAGE_BASE="/mnt/apps"
REQUIRED_APPS=("portainer" "heimdall" "n8n")

# Interactive mode - set to "false" to skip prompts (auto-yes)
INTERACTIVE_MODE="${INTERACTIVE_MODE:-true}"

# Track deployed services for summary
declare -A DEPLOYED_SERVICES

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
# USER INPUT FUNCTIONS
################################################################################

# Ask user for confirmation (y/N with default to Yes)
ask_user() {
    local prompt=$1
    local default=${2:-y}  # Default to 'y' if not specified
    
    # Skip prompt if not in interactive mode
    if [ "${INTERACTIVE_MODE}" != "true" ]; then
        return 0  # Auto-yes
    fi
    
    local response
    if [ "$default" = "y" ]; then
        read -p "${prompt} [Y/n] " response
        response=${response:-y}  # Default to yes
    else
        read -p "${prompt} [y/N] " response
        response=${response:-n}  # Default to no
    fi
    
    case "$response" in
        [yY][eE][sS]|[yY]) 
            return 0
            ;;
        *)
            return 1
            ;;
    esac
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

check_helm() {
    print_step "Checking for Helm..."
    
    if ! command -v helm &> /dev/null; then
        print_warning "Helm not found. Installing Helm 3..."
        
        if curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash; then
            print_success "Helm installed successfully"
        else
            print_error "Failed to install Helm"
            exit 1
        fi
    else
        print_success "Helm found: $(helm version --short 2>/dev/null || echo 'installed')"
    fi
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
    
    # Wait for nodes to be ready (handles K3s startup race condition)
    print_step "Waiting for cluster nodes to be Ready..."
    local max_wait=60
    local waited=0
    
    while [ $waited -lt $max_wait ]; do
        local ready_nodes=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready" || echo "0")
        local total_nodes=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
        
        if [ "$ready_nodes" -gt 0 ] && [ "$ready_nodes" -eq "$total_nodes" ]; then
            print_success "All ${ready_nodes} node(s) are Ready"
            return 0
        fi
        
        if [ $waited -eq 0 ]; then
            print_info "Waiting for nodes to become Ready... (${waited}s/${max_wait}s)"
        fi
        
        sleep 2
        waited=$((waited + 2))
    done
    
    print_warning "Nodes may not be fully ready yet, but continuing..."
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
    check_helm
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
    # Ask for user confirmation
    if ! ask_user "Deploy Portainer (Container Management UI)?"; then
        print_info "Skipping Portainer deployment..."
        echo ""
        return 0
    fi
    
    print_step "Deploying Portainer (Container Management UI)..."
    
    # Check if already deployed
    if is_deployed "deployment" "portainer" "portainer"; then
        print_info "Portainer is already deployed (idempotent)"
        print_info "To redeploy, delete it first: kubectl delete -f manifests/portainer-admin.yaml"
        DEPLOYED_SERVICES[portainer]="deployed"
    else
        if apply_manifest "${MANIFESTS_DIR}/portainer-admin.yaml" "Portainer"; then
            DEPLOYED_SERVICES[portainer]="deployed"
            print_info "Access Portainer at: http://YOUR_SERVER_IP:30777"
        fi
    fi
    
    echo ""
}

deploy_heimdall() {
    # Ask for user confirmation
    if ! ask_user "Deploy Heimdall (Application Dashboard)?"; then
        print_info "Skipping Heimdall deployment..."
        echo ""
        return 0
    fi
    
    print_step "Deploying Heimdall (Application Dashboard)..."
    
    # Verify storage
    if [ ! -d "${STORAGE_BASE}/heimdall" ]; then
        print_warning "Heimdall storage directory not found, creating..."
        mkdir -p "${STORAGE_BASE}/heimdall"
        chown -R 1000:1000 "${STORAGE_BASE}/heimdall"
    fi
    
    if is_deployed "deployment" "heimdall-manual" "default"; then
        print_info "Heimdall is already deployed (idempotent)"
        DEPLOYED_SERVICES[heimdall]="deployed"
    else
        if apply_manifest "${MANIFESTS_DIR}/heimdall-manual.yaml" "Heimdall"; then
            DEPLOYED_SERVICES[heimdall]="deployed"
            print_info "Access Heimdall at: http://YOUR_SERVER_IP:30088"
        fi
    fi
    
    echo ""
}

deploy_n8n() {
    # Ask for user confirmation
    if ! ask_user "Deploy n8n (Workflow Automation)?"; then
        print_info "Skipping n8n deployment..."
        echo ""
        return 0
    fi
    
    print_step "Deploying n8n (Workflow Automation)..."
    
    # Verify storage
    if [ ! -d "${STORAGE_BASE}/n8n" ]; then
        print_warning "n8n storage directory not found, creating..."
        mkdir -p "${STORAGE_BASE}/n8n"
        chown -R 1000:1000 "${STORAGE_BASE}/n8n"
    fi
    
    if is_deployed "deployment" "n8n" "default"; then
        print_info "n8n is already deployed (idempotent)"
        DEPLOYED_SERVICES[n8n]="deployed"
    else
        if apply_manifest "${MANIFESTS_DIR}/n8n-deployment.yaml" "n8n"; then
            DEPLOYED_SERVICES[n8n]="deployed"
            print_info "Access n8n at: http://YOUR_SERVER_IP:30080"
        fi
    fi
    
    echo ""
}

deploy_web_demo() {
    # Ask for user confirmation
    if ! ask_user "Deploy web-demo applications?"; then
        print_info "Skipping web-demo deployment..."
        echo ""
        return 0
    fi
    
    print_step "Deploying web-demo applications..."
    
    if [ ! -d "${MANIFESTS_DIR}/web-demo" ]; then
        print_warning "web-demo directory not found, skipping..."
        return 0
    fi
    
    # Use array to safely handle filenames with spaces
    local demo_manifests=()
    while IFS= read -r -d '' manifest; do
        demo_manifests+=("$manifest")
    done < <(find "${MANIFESTS_DIR}/web-demo" -name "*.yaml" -o -name "*.yml" -print0)
    
    if [ ${#demo_manifests[@]} -eq 0 ]; then
        print_info "No web-demo manifests found, skipping..."
        return 0
    fi
    
    for manifest in "${demo_manifests[@]}"; do
        local filename=$(basename "${manifest}")
        if apply_manifest "${manifest}" "web-demo/${filename}"; then
            DEPLOYED_SERVICES[web-demo]="deployed"
        fi
    done
    
    echo ""
}

deploy_netdata() {
    # Ask for user confirmation
    if ! ask_user "Deploy Netdata (Real-time Monitoring)?"; then
        print_info "Skipping Netdata deployment..."
        echo ""
        return 0
    fi
    
    print_step "Deploying Netdata (Real-time Monitoring)..."
    
    # Check if already installed
    if command -v netdata &> /dev/null || systemctl is-active --quiet netdata 2>/dev/null; then
        print_info "Netdata is already installed (idempotent)"
        DEPLOYED_SERVICES[netdata]="deployed"
        echo ""
        return 0
    fi
    
    # Install Netdata
    print_info "Downloading and installing Netdata..."
    if wget -O /tmp/netdata-kickstart.sh https://get.netdata.cloud/kickstart.sh 2>/dev/null && \
       sh /tmp/netdata-kickstart.sh --stable-channel --disable-telemetry --non-interactive --dont-wait; then
        print_success "Netdata installed successfully"
        DEPLOYED_SERVICES[netdata]="deployed"
        print_info "Access Netdata at: http://YOUR_SERVER_IP:19999"
    else
        print_error "Failed to install Netdata"
    fi
    
    # Cleanup
    rm -f /tmp/netdata-kickstart.sh
    echo ""
}

deploy_crowdsec() {
    # Ask for user confirmation
    if ! ask_user "Deploy CrowdSec (Security Monitoring)?"; then
        print_info "Skipping CrowdSec deployment..."
        echo ""
        return 0
    fi
    
    print_step "Deploying CrowdSec (Security Monitoring)..."
    
    # Check if values file exists
    if [ ! -f "${HELM_VALUES_DIR}/crowdsec-values.yaml" ]; then
        print_error "CrowdSec values file not found: ${HELM_VALUES_DIR}/crowdsec-values.yaml"
        echo ""
        return 1
    fi
    
    # Add Helm repo
    print_info "Adding CrowdSec Helm repository..."
    helm repo add crowdsec https://crowdsecurity.github.io/helm-charts 2>/dev/null || true
    helm repo update crowdsec
    
    # Check if already deployed
    if helm list -n crowdsec 2>/dev/null | grep -q "crowdsec"; then
        print_info "CrowdSec is already deployed (idempotent)"
        DEPLOYED_SERVICES[crowdsec]="deployed"
    else
        print_info "Installing CrowdSec with local values..."
        if helm upgrade --install crowdsec crowdsec/crowdsec \
            --create-namespace \
            -n crowdsec \
            -f "${HELM_VALUES_DIR}/crowdsec-values.yaml" \
            --wait \
            --timeout 5m; then
            print_success "CrowdSec deployed successfully"
            DEPLOYED_SERVICES[crowdsec]="deployed"
        else
            print_error "Failed to deploy CrowdSec"
        fi
    fi
    
    echo ""
}

deploy_adguard() {
    # Ask for user confirmation
    if ! ask_user "Deploy AdGuard Home (DNS Filtering)?"; then
        print_info "Skipping AdGuard Home deployment..."
        echo ""
        return 0
    fi
    
    print_step "Deploying AdGuard Home (DNS Filtering)..."
    
    # Check if values file exists
    if [ ! -f "${HELM_VALUES_DIR}/adguard-values.yaml" ]; then
        print_error "AdGuard values file not found: ${HELM_VALUES_DIR}/adguard-values.yaml"
        echo ""
        return 1
    fi
    
    # Add Helm repo
    print_info "Adding AdGuard Home Helm repository..."
    helm repo add gabe565 https://charts.gabe565.com 2>/dev/null || true
    helm repo update gabe565
    
    # Check if already deployed
    if helm list -n adguard 2>/dev/null | grep -q "adguard"; then
        print_info "AdGuard Home is already deployed (idempotent)"
        DEPLOYED_SERVICES[adguard]="deployed"
    else
        print_info "Installing AdGuard Home with local values..."
        if helm upgrade --install adguard gabe565/adguard-home \
            --create-namespace \
            -n adguard \
            -f "${HELM_VALUES_DIR}/adguard-values.yaml" \
            --wait \
            --timeout 5m; then
            print_success "AdGuard Home deployed successfully"
            DEPLOYED_SERVICES[adguard]="deployed"
            print_info "Access AdGuard at: http://YOUR_SERVER_IP:3000"
        else
            print_error "Failed to deploy AdGuard Home"
        fi
    fi
    
    echo ""
}

deploy_all_manifests() {
    print_banner "DEPLOYING MANIFESTS"
    
    if [ "${INTERACTIVE_MODE}" = "true" ]; then
        print_info "Interactive mode enabled. You will be asked before deploying each application."
        print_info "Core infrastructure checks have already passed automatically."
        echo ""
    else
        print_info "Auto-deployment mode (all applications will be deployed)."
        echo ""
    fi
    
    # Deploy Kubernetes manifests
    deploy_portainer
    deploy_heimdall
    deploy_n8n
    deploy_web_demo
    
    # Deploy system monitoring
    deploy_netdata
    
    # Deploy Helm charts
    deploy_crowdsec
    deploy_adguard
    
    print_success "Deployment process completed!"
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
    print_banner "DEPLOYMENT COMPLETE - ACCESS DASHBOARD"
    
    # Detect server IP
    local SERVER_IP=$(hostname -I | awk '{print $1}')
    if [ -z "$SERVER_IP" ]; then
        SERVER_IP="YOUR_SERVER_IP"
    fi
    
    print_success "Server LAN IP: ${SERVER_IP}"
    echo ""
    
    # Build service table dynamically
    local has_services=false
    
    echo "SERVICE           URL"
    echo "----------------- --------------------------------------------"
    
    # Check Portainer
    if [ "${DEPLOYED_SERVICES[portainer]:-}" = "deployed" ]; then
        local portainer_port=$(kubectl get svc -n portainer portainer -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}' 2>/dev/null || echo "30777")
        if [ -n "$portainer_port" ]; then
            printf "%-17s http://%s:%s\n" "Portainer" "$SERVER_IP" "$portainer_port"
            has_services=true
        fi
    fi
    
    # Check Heimdall
    if [ "${DEPLOYED_SERVICES[heimdall]:-}" = "deployed" ]; then
        local heimdall_port=$(kubectl get svc heimdall-svc-manual -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "30088")
        if [ -n "$heimdall_port" ]; then
            printf "%-17s http://%s:%s\n" "Heimdall" "$SERVER_IP" "$heimdall_port"
            has_services=true
        fi
    fi
    
    # Check n8n
    if [ "${DEPLOYED_SERVICES[n8n]:-}" = "deployed" ]; then
        local n8n_port=$(kubectl get svc n8n -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "30080")
        if [ -n "$n8n_port" ]; then
            printf "%-17s http://%s:%s\n" "n8n" "$SERVER_IP" "$n8n_port"
            has_services=true
        fi
    fi
    
    # Check Web Demo
    if [ "${DEPLOYED_SERVICES[web-demo]:-}" = "deployed" ]; then
        local webdemo_port=$(kubectl get svc web-demo-svc -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "30090")
        if [ -n "$webdemo_port" ]; then
            printf "%-17s http://%s:%s\n" "Web Demo" "$SERVER_IP" "$webdemo_port"
            has_services=true
        fi
    fi
    
    # Check AdGuard (hostNetwork, port 3000)
    if [ "${DEPLOYED_SERVICES[adguard]:-}" = "deployed" ]; then
        printf "%-17s http://%s:3000\n" "AdGuard Home" "$SERVER_IP"
        has_services=true
    fi
    
    # Check Netdata (hostNetwork, port 19999)
    if [ "${DEPLOYED_SERVICES[netdata]:-}" = "deployed" ]; then
        printf "%-17s http://%s:19999\n" "Netdata" "$SERVER_IP"
        has_services=true
    fi
    
    # Check CrowdSec (no web UI by default, just note it's running)
    if [ "${DEPLOYED_SERVICES[crowdsec]:-}" = "deployed" ]; then
        printf "%-17s %s\n" "CrowdSec" "(Running - CLI: cscli)"
        has_services=true
    fi
    
    if [ "$has_services" = false ]; then
        echo "No services were deployed."
    fi
    
    echo ""
    print_info "Useful commands:"
    echo "  kubectl get all --all-namespaces    # View all resources"
    echo "  kubectl get pods --all-namespaces   # Check pod status"
    echo "  kubectl logs <pod-name>             # View pod logs"
    echo "  helm list -A                        # List Helm releases"
    echo ""
    
    print_warning "Security Reminder:"
    echo "  Remember to set strong passwords on first login!"
    echo "  This is a development environment - do not expose to the internet."
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
