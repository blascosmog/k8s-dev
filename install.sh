#!/bin/bash

# k8s-dev Installation Script
# This script deploys Kubernetes manifests and Helm charts

set -e

echo "================================================"
echo "k8s-dev Installation Script"
echo "================================================"
echo ""

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo -e "${YELLOW}ℹ $1${NC}"
}

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    print_error "kubectl is not installed or not in PATH"
    exit 1
fi

# Check if kubectl can connect to cluster
if ! kubectl cluster-info &> /dev/null; then
    print_error "Cannot connect to Kubernetes cluster"
    exit 1
fi

print_success "Connected to Kubernetes cluster"
echo ""

# Function to apply manifest
apply_manifest() {
    local manifest=$1
    local name=$2
    
    if [ -f "$manifest" ]; then
        print_info "Deploying $name..."
        if kubectl apply -f "$manifest"; then
            print_success "$name deployed successfully"
        else
            print_error "Failed to deploy $name"
            return 1
        fi
    else
        print_error "Manifest not found: $manifest"
        return 1
    fi
}

# Deploy manifests
echo "Deploying Kubernetes manifests..."
echo ""

# Deploy Portainer
apply_manifest "manifests/portainer-admin.yaml" "Portainer"

# Deploy Heimdall
print_info "Checking if /mnt/apps/heimdall exists on nodes..."
print_info "Note: Ensure this path exists on your nodes before deploying"
apply_manifest "manifests/heimdall-manual.yaml" "Heimdall"

# Deploy n8n
apply_manifest "manifests/n8n-deployment.yaml" "n8n"

# Deploy web-demo if directory exists
if [ -d "manifests/web-demo" ]; then
    echo ""
    print_info "Deploying web-demo applications..."
    for manifest in manifests/web-demo/*.yaml; do
        if [ -f "$manifest" ]; then
            filename=$(basename "$manifest")
            apply_manifest "$manifest" "web-demo/$filename"
        fi
    done
fi

echo ""
echo "================================================"
echo "Deployment Summary"
echo "================================================"
echo ""

# Check deployment status
print_info "Checking deployment status..."
echo ""

kubectl get deployments --all-namespaces | grep -E "portainer|heimdall|n8n" || print_info "No matching deployments found yet"

echo ""
echo "================================================"
echo "Installation Complete!"
echo "================================================"
echo ""

print_info "To check the status of your deployments:"
echo "  kubectl get all"
echo ""

print_info "To access services locally, use port-forwarding:"
echo "  kubectl port-forward svc/portainer 9000:9000"
echo "  kubectl port-forward svc/heimdall 8080:80"
echo "  kubectl port-forward svc/n8n 5678:5678"
echo ""

print_success "Installation script completed"
